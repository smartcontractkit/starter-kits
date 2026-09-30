module data_feeds::router {
    use std::error;
    use std::event;
    use std::signer;
    use std::string::String;
    use std::vector;

    use aptos_framework::object::{Self, ExtendRef, TransferRef};

    use data_feeds::registry::{Self, Benchmark, Report};

    const APP_OBJECT_SEED: vector<u8> = b"ROUTER";

    struct Router has key, store, drop {
        owner_address: address,
        pending_owner_address: address,
        extend_ref: ExtendRef,
        transfer_ref: TransferRef
    }

    #[event]
    struct OwnershipTransferRequested has drop, store {
        from: address,
        to: address
    }

    #[event]
    struct OwnershipTransferred has drop, store {
        from: address,
        to: address
    }

    const ENOT_OWNER: u64 = 0;
    const ECANNOT_TRANSFER_TO_SELF: u64 = 1;
    const ENOT_PROPOSED_OWNER: u64 = 2;

    fun assert_is_owner(router: &Router, target_address: address) {
        assert!(
            router.owner_address == target_address, error::invalid_argument(ENOT_OWNER)
        );
    }

    fun init_module(publisher: &signer) {
        assert!(signer::address_of(publisher) == @data_feeds, 1);

        let constructor_ref = object::create_named_object(publisher, APP_OBJECT_SEED);

        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let object_signer = object::generate_signer(&constructor_ref);

        move_to(
            &object_signer,
            Router {
                owner_address: @owner,
                pending_owner_address: @0x0,
                extend_ref,
                transfer_ref
            }
        );
    }

    inline fun get_state_addr(): address {
        object::create_object_address(&@data_feeds, APP_OBJECT_SEED)
    }

    public fun get_benchmarks(
        _authority: &signer, feed_ids: vector<vector<u8>>, _billing_data: vector<u8>
    ): vector<Benchmark> acquires Router {
        let _router = borrow_global<Router>(get_state_addr());

        registry::get_benchmarks_unchecked(feed_ids)
    }

    public fun get_reports(
        _authority: &signer, feed_ids: vector<vector<u8>>, _billing_data: vector<u8>
    ): vector<Report> acquires Router {
        let _router = borrow_global<Router>(get_state_addr());

        registry::get_reports_unchecked(feed_ids)
    }

    #[view]
    public fun get_descriptions(feed_ids: vector<vector<u8>>): vector<String> acquires Router {
        let _router = borrow_global<Router>(get_state_addr());

        let results = registry::get_feed_metadata(feed_ids);
        vector::map(
            results, |metadata| registry::get_feed_metadata_description(&metadata)
        )
    }

    public entry fun configure_feeds(
        authority: &signer,
        feed_ids: vector<vector<u8>>,
        descriptions: vector<String>,
        config_id: vector<u8>,
        _fee_config_id: vector<u8>
    ) acquires Router {
        let router = borrow_global<Router>(get_state_addr());
        assert_is_owner(router, signer::address_of(authority));

        registry::set_feeds_unchecked(feed_ids, descriptions, config_id);
    }

    // Ownership functions
    #[view]
    public fun get_owner(): address acquires Router {
        let router = borrow_global<Router>(get_state_addr());
        router.owner_address
    }

    public entry fun transfer_ownership(authority: &signer, to: address) acquires Router {
        let router = borrow_global_mut<Router>(get_state_addr());
        assert_is_owner(router, signer::address_of(authority));
        assert!(
            router.owner_address != to,
            error::invalid_argument(ECANNOT_TRANSFER_TO_SELF)
        );

        router.pending_owner_address = to;

        event::emit(OwnershipTransferRequested { from: router.owner_address, to });
    }

    public entry fun accept_ownership(authority: &signer) acquires Router {
        let router = borrow_global_mut<Router>(get_state_addr());
        assert!(
            router.pending_owner_address == signer::address_of(authority),
            error::permission_denied(ENOT_PROPOSED_OWNER)
        );

        let old_owner_address = router.owner_address;
        router.owner_address = router.pending_owner_address;
        router.pending_owner_address = @0x0;

        event::emit(
            OwnershipTransferred { from: old_owner_address, to: router.owner_address }
        );
    }

    #[test_only]
    fun set_up_test(publisher: &signer) {
        init_module(publisher);
    }

    #[test(owner = @owner, publisher = @data_feeds, new_owner = @0xbeef)]
    fun test_transfer_ownership_success(
        owner: &signer, publisher: &signer, new_owner: &signer
    ) acquires Router {
        set_up_test(publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(owner, signer::address_of(new_owner));
        accept_ownership(new_owner);

        assert!(get_owner() == signer::address_of(new_owner), 2);
    }

    #[test(publisher = @data_feeds, unknown_user = @0xbeef)]
    #[expected_failure(abort_code = 65536, location = data_feeds::router)]
    fun test_transfer_ownership_failure_not_owner(
        publisher: &signer, unknown_user: &signer
    ) acquires Router {
        set_up_test(publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(unknown_user, signer::address_of(unknown_user));
    }

    #[test(owner = @owner, publisher = @data_feeds)]
    #[expected_failure(abort_code = 65537, location = data_feeds::router)]
    fun test_transfer_ownership_failure_transfer_to_self(
        owner: &signer, publisher: &signer
    ) acquires Router {
        set_up_test(publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(owner, signer::address_of(owner));
    }

    #[test(owner = @owner, publisher = @data_feeds, new_owner = @0xbeef)]
    #[expected_failure(abort_code = 327682, location = data_feeds::router)]
    fun test_transfer_ownership_failure_not_proposed_owner(
        owner: &signer, publisher: &signer, new_owner: &signer
    ) acquires Router {
        set_up_test(publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(owner, @0xfeeb);
        accept_ownership(new_owner);
    }
}
