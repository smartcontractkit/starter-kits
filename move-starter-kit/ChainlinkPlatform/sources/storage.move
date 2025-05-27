/// The storage module stores all the state associated with the dispatch service.
module platform::storage {
    use std::option;
    use std::string;
    use std::signer;
    use std::vector;

    use aptos_std::table::{Self, Table};
    use aptos_std::smart_table::{SmartTable, Self};
    use aptos_std::type_info::{Self, TypeInfo};

    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::function_info::FunctionInfo;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, ExtendRef, TransferRef, Object};

    const APP_OBJECT_SEED: vector<u8> = b"STORAGE";

    friend platform::forwarder;

    const E_UNKNOWN_RECEIVER: u64 = 1;
    const E_INVALID_METADATA_LENGTH: u64 = 2;

    struct Entry has key, store, drop {
        metadata: Object<Metadata>,
        extend_ref: ExtendRef
    }

    struct Dispatcher has key {
        /// Tracks the input type to the dispatch handler.
        dispatcher: Table<TypeInfo, Entry>,
        address_to_typeinfo: Table<address, TypeInfo>,
        /// Used to store temporary data for dispatching.
        extend_ref: ExtendRef,
        transfer_ref: TransferRef
    }

    struct DispatcherV2 has key {
        dispatcher: SmartTable<TypeInfo, Entry>,
        address_to_typeinfo: SmartTable<address, TypeInfo>
    }

    /// Store the data to dispatch here.
    struct Storage has drop, key {
        metadata: vector<u8>,
        data: vector<u8>
    }

    struct ReportMetadata has key, store, drop {
        workflow_cid: vector<u8>,
        workflow_name: vector<u8>,
        workflow_owner: vector<u8>,
        report_id: vector<u8>
    }

    /// Registers an account and callback for future dispatching, and a proof type `T`
    /// for the callback function to retrieve arguments. Note that the function will
    /// abort if the account has already been registered.
    ///
    /// The address of `account` is used to represent the callback by the dispatcher.
    /// See the `dispatch` function in `forwarder.move`.
    ///
    /// Providing an instance of `T` guarantees that only a privileged module can call `register` for that type.
    /// The type `T` should ideally only have the `drop` ability and no other abilities to prevent
    /// copying and persisting in global storage.
    public fun register<T: drop>(
        account: &signer, callback: FunctionInfo, _proof: T
    ) acquires Dispatcher, DispatcherV2 {
        let typename = type_info::type_name<T>();
        let constructor_ref =
            object::create_named_object(&storage_signer(), *string::bytes(&typename));
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let metadata =
            fungible_asset::add_fungibility(
                &constructor_ref,
                option::none(),
                // this was `typename` but it fails due to ENAME_TOO_LONG
                string::utf8(b"storage"),
                string::utf8(b"dis"),
                0,
                string::utf8(b""),
                string::utf8(b"")
            );
        dispatchable_fungible_asset::register_derive_supply_dispatch_function(
            &constructor_ref, option::some(callback)
        );

        let dispatcher = borrow_global_mut<DispatcherV2>(storage_address());
        smart_table::add(
            &mut dispatcher.dispatcher,
            type_info::type_of<T>(),
            Entry { metadata, extend_ref }
        );
        smart_table::add(
            &mut dispatcher.address_to_typeinfo,
            signer::address_of(account),
            type_info::type_of<T>()
        );
    }

    public entry fun migrate_to_v2(
        callback_addresses: vector<address>
    ) acquires Dispatcher, DispatcherV2 {
        let addr = storage_address();

        if (!exists<DispatcherV2>(addr)) {
            move_to(
                &storage_signer(),
                DispatcherV2 {
                    dispatcher: smart_table::new(),
                    address_to_typeinfo: smart_table::new()
                }
            );
        };

        let dispatcher = borrow_global_mut<Dispatcher>(addr);
        let dispatcher_v2 = borrow_global_mut<DispatcherV2>(addr);

        vector::for_each_ref(
            &callback_addresses,
            |callback_address| {
                // Aborts if the callback address does not exist.
                let type_info =
                    table::remove(
                        &mut dispatcher.address_to_typeinfo, *callback_address
                    );
                let entry = table::remove(&mut dispatcher.dispatcher, type_info);

                smart_table::add(
                    &mut dispatcher_v2.address_to_typeinfo,
                    *callback_address,
                    type_info
                );
                smart_table::add(&mut dispatcher_v2.dispatcher, type_info, entry);
            }
        );
    }

    /// Insert into this module as the callback needs to retrieve and avoid a cyclical dependency:
    /// engine -> storage and then engine -> callback -> storage
    public(friend) fun insert(
        receiver: address, callback_metadata: vector<u8>, callback_data: vector<u8>
    ): Object<Metadata> acquires Dispatcher, DispatcherV2 {
        // TODO: delete this clause after migration completes
        if (!exists<DispatcherV2>(storage_address())) {
          let dispatcher = borrow_global<Dispatcher>(storage_address());
          let typeinfo = *table::borrow(&dispatcher.address_to_typeinfo, receiver);
          assert!(
              table::contains(&dispatcher.dispatcher, typeinfo),
              E_UNKNOWN_RECEIVER
              );
          let Entry { metadata: asset_metadata, extend_ref } =
            table::borrow(&dispatcher.dispatcher, typeinfo);
          let obj_signer = object::generate_signer_for_extending(extend_ref);
          move_to(&obj_signer, Storage { data: callback_data, metadata: callback_metadata });
          return *asset_metadata
        };

        let dispatcher = borrow_global<DispatcherV2>(storage_address());
        let typeinfo = *smart_table::borrow(&dispatcher.address_to_typeinfo, receiver);
        assert!(
            smart_table::contains(&dispatcher.dispatcher, typeinfo),
            E_UNKNOWN_RECEIVER
        );
        let Entry { metadata: asset_metadata, extend_ref } =
            smart_table::borrow(&dispatcher.dispatcher, typeinfo);
        let obj_signer = object::generate_signer_for_extending(extend_ref);
        move_to(&obj_signer, Storage { data: callback_data, metadata: callback_metadata });
        *asset_metadata
    }

    public(friend) fun storage_exists(obj_address: address): bool {
        object::object_exists<Storage>(obj_address)
    }

    /// Second half of the process for retrieving. This happens outside engine to prevent the
    /// cyclical dependency.
    public fun retrieve<T: drop>(_proof: T): (vector<u8>, vector<u8>) acquires Dispatcher, DispatcherV2, Storage {
        // TODO: delete this clause after migration completes
        if (!exists<DispatcherV2>(storage_address())) {
          let dispatcher = borrow_global<Dispatcher>(storage_address());
          let typeinfo = type_info::type_of<T>();
          let Entry { metadata: _, extend_ref } =
              table::borrow(&dispatcher.dispatcher, typeinfo);
          let obj_address = object::address_from_extend_ref(extend_ref);
          let data = move_from<Storage>(obj_address);
          return (data.metadata, data.data)
        };
        let dispatcher = borrow_global<DispatcherV2>(storage_address());
        let typeinfo = type_info::type_of<T>();
        let Entry { metadata: _, extend_ref } =
            smart_table::borrow(&dispatcher.dispatcher, typeinfo);
        let obj_address = object::address_from_extend_ref(extend_ref);
        let data = move_from<Storage>(obj_address);
        (data.metadata, data.data)
    }

    #[view]
    public fun parse_report_metadata(metadata: vector<u8>): ReportMetadata {
        // workflow_cid             // offset 0,  size 32
        // workflow_name            // offset 32, size 10
        // workflow_owner           // offset 42, size 20
        // report_id                // offset 62, size  2
        assert!(vector::length(&metadata) == 64, E_INVALID_METADATA_LENGTH);

        let workflow_cid = vector::slice(&metadata, 0, 32);
        let workflow_name = vector::slice(&metadata, 32, 42);
        let workflow_owner = vector::slice(&metadata, 42, 62);
        let report_id = vector::slice(&metadata, 62, 64);

        ReportMetadata { workflow_cid, workflow_name, workflow_owner, report_id }
    }

    /// Prepares the dispatch table.
    fun init_module(publisher: &signer) {
        assert!(signer::address_of(publisher) == @platform, 1);

        let constructor_ref = object::create_named_object(publisher, APP_OBJECT_SEED);

        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        move_to(
            &object_signer,
            Dispatcher {
                dispatcher: table::new(),
                address_to_typeinfo: table::new(),
                extend_ref,
                transfer_ref
            }
        );

        move_to(
            &object_signer,
            DispatcherV2 {
                dispatcher: smart_table::new(),
                address_to_typeinfo: smart_table::new()
            }
        );
    }

    inline fun storage_address(): address {
        object::create_object_address(&@platform, APP_OBJECT_SEED)
    }

    inline fun storage_signer(): signer acquires Dispatcher {
        object::generate_signer_for_extending(
            &borrow_global<Dispatcher>(storage_address()).extend_ref
        )
    }

    // Struct accessors

    public fun get_report_metadata_workflow_cid(
        report_metadata: &ReportMetadata
    ): vector<u8> {
        report_metadata.workflow_cid
    }

    public fun get_report_metadata_workflow_name(
        report_metadata: &ReportMetadata
    ): vector<u8> {
        report_metadata.workflow_name
    }

    public fun get_report_metadata_workflow_owner(
        report_metadata: &ReportMetadata
    ): vector<u8> {
        report_metadata.workflow_owner
    }

    public fun get_report_metadata_report_id(
        report_metadata: &ReportMetadata
    ): vector<u8> {
        report_metadata.report_id
    }

    #[test_only]
    public fun init_module_for_testing(publisher: &signer) {
        init_module(publisher);
    }

    #[test]
    fun test_parse_report_metadata() {
        let metadata =
            x"6d795f6964000000000000000000000000000000000000000000000000000000000000000000deadbeef00000000000000000000000000000000000000510001";
        let expected_workflow_cid =
            x"6d795f6964000000000000000000000000000000000000000000000000000000";
        let expected_workflow_name = x"000000000000DEADBEEF";
        let expected_workflow_owner = x"0000000000000000000000000000000000000051";
        let expected_report_id = x"0001";

        let parsed_metadata = parse_report_metadata(metadata);
        assert!(parsed_metadata.workflow_cid == expected_workflow_cid, 1);
        assert!(parsed_metadata.workflow_name == expected_workflow_name, 1);
        assert!(parsed_metadata.workflow_owner == expected_workflow_owner, 1);
        assert!(parsed_metadata.report_id == expected_report_id, 1);
    }

    #[test_only]
    fun init_module_deprecated(publisher: &signer) {
        assert!(signer::address_of(publisher) == @platform, 1);

        let constructor_ref = object::create_named_object(publisher, APP_OBJECT_SEED);

        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        move_to(
            &object_signer,
            Dispatcher {
                dispatcher: table::new(),
                address_to_typeinfo: table::new(),
                extend_ref,
                transfer_ref
            }
        );
    }

    #[test_only]
    fun register_deprecated<T: drop>(
        account: &signer, callback: FunctionInfo, _proof: T
    ) acquires Dispatcher {
        let typename = type_info::type_name<T>();
        let constructor_ref =
            object::create_named_object(&storage_signer(), *string::bytes(&typename));
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let metadata =
            fungible_asset::add_fungibility(
                &constructor_ref,
                option::none(),
                // this was `typename` but it fails due to ENAME_TOO_LONG
                string::utf8(b"storage"),
                string::utf8(b"dis"),
                0,
                string::utf8(b""),
                string::utf8(b"")
            );
        dispatchable_fungible_asset::register_derive_supply_dispatch_function(
            &constructor_ref, option::some(callback)
        );

        let dispatcher = borrow_global_mut<Dispatcher>(storage_address());
        table::add(
            &mut dispatcher.dispatcher,
            type_info::type_of<T>(),
            Entry { metadata, extend_ref }
        );
        table::add(
            &mut dispatcher.address_to_typeinfo,
            signer::address_of(account),
            type_info::type_of<T>()
        );
    }

    #[test_only]
    struct TestProof has drop {}

    #[test_only]
    struct TestProof2 has drop {}

    #[test_only]
    struct TestProof3 has drop {}

    #[test_only]
    struct TestProof4 has drop {}

    #[test_only]
    public fun test_callback<T: key>(_metadata: Object<T>): option::Option<u128> {
        option::none()
    }

    #[test(publisher = @platform)]
    fun test_v2_migration(publisher: &signer) acquires Dispatcher, DispatcherV2, Storage {
        init_module_deprecated(publisher);

        let test_callback =
            aptos_framework::function_info::new_function_info(
                publisher,
                string::utf8(b"storage"),
                string::utf8(b"test_callback")
            );

        register_deprecated(publisher, test_callback, TestProof {});

        let (derived_publisher, _) =
            aptos_framework::account::create_resource_account(
                publisher, b"TEST_V2_MIGRATION"
            );
        let (derived_publisher2, _) =
            aptos_framework::account::create_resource_account(
                publisher, b"TEST_V2_MIGRATION_2"
            );
        let (derived_publisher3, _) =
            aptos_framework::account::create_resource_account(
                publisher, b"TEST_V2_MIGRATION_3"
            );

        register_deprecated(&derived_publisher, test_callback, TestProof2 {});
        register_deprecated(&derived_publisher2, test_callback, TestProof3 {});

        let callback_metadata = vector[1,2,3,4];
        let callback_data = vector[5,6,7,8,9];

        // test initial migration
        {
            // test that insert and retrieve work before migration
            insert(signer::address_of(publisher), callback_metadata, callback_data);
            let (received_metadata, received_data) = retrieve<TestProof>(TestProof{});
            assert!(callback_metadata == received_metadata, 1);
            assert!(callback_data == received_data, 1);

            let derived_addr = signer::address_of(&derived_publisher);
            migrate_to_v2(vector[@platform, derived_addr]);

            // test that insert and retrieve still work after migration
            insert(signer::address_of(publisher), callback_metadata, callback_data);
            let (received_metadata, received_data) = retrieve<TestProof>(TestProof{});
            assert!(callback_metadata == received_metadata, 1);
            assert!(callback_data == received_data, 1);

            let dispatcher = borrow_global<Dispatcher>(storage_address());
            assert!(
                !table::contains(
                    &dispatcher.dispatcher, type_info::type_of<TestProof>()
                ),
                1
            );
            assert!(!table::contains(&dispatcher.address_to_typeinfo, @platform), 1);
            assert!(
                !table::contains(
                    &dispatcher.dispatcher, type_info::type_of<TestProof2>()
                ),
                1
            );
            assert!(!table::contains(&dispatcher.address_to_typeinfo, derived_addr), 1);

            let dispatcher_v2 = borrow_global<DispatcherV2>(storage_address());
            assert!(
                smart_table::contains(
                    &dispatcher_v2.dispatcher, type_info::type_of<TestProof>()
                ),
                1
            );
            assert!(
                smart_table::contains(&dispatcher_v2.address_to_typeinfo, @platform),
                1
            );
            assert!(
                smart_table::contains(
                    &dispatcher_v2.dispatcher, type_info::type_of<TestProof2>()
                ),
                1
            );
            assert!(
                smart_table::contains(&dispatcher_v2.address_to_typeinfo, derived_addr),
                1
            );
        };

        // migrate a second time, when DispatcherV2 already exists.
        {
            let derived_addr = signer::address_of(&derived_publisher2);
            migrate_to_v2(vector[derived_addr]);

            let dispatcher = borrow_global<Dispatcher>(storage_address());
            assert!(
                !table::contains(
                    &dispatcher.dispatcher, type_info::type_of<TestProof3>()
                ),
                1
            );
            assert!(!table::contains(&dispatcher.address_to_typeinfo, derived_addr), 1);

            let dispatcher_v2 = borrow_global<DispatcherV2>(storage_address());
            assert!(
                smart_table::contains(
                    &dispatcher_v2.dispatcher, type_info::type_of<TestProof3>()
                ),
                1
            );
            assert!(
                smart_table::contains(&dispatcher_v2.address_to_typeinfo, derived_addr),
                1
            );
        };

        // test the upgraded register function
        {
            let derived_addr = signer::address_of(&derived_publisher3);
            register(&derived_publisher3, test_callback, TestProof4 {});

            let dispatcher = borrow_global<Dispatcher>(storage_address());
            assert!(
                !table::contains(
                    &dispatcher.dispatcher, type_info::type_of<TestProof4>()
                ),
                1
            );
            assert!(!table::contains(&dispatcher.address_to_typeinfo, derived_addr), 1);

            let dispatcher_v2 = borrow_global<DispatcherV2>(storage_address());
            assert!(
                smart_table::contains(
                    &dispatcher_v2.dispatcher, type_info::type_of<TestProof4>()
                ),
                1
            );
            assert!(
                smart_table::contains(&dispatcher_v2.address_to_typeinfo, derived_addr),
                1
            );
        }
    }
}
