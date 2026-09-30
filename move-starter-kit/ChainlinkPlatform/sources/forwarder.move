module platform::forwarder {
    use aptos_framework::object::{Self, ExtendRef, TransferRef};
    use aptos_std::smart_table::{SmartTable, Self};

    use std::error;
    use std::event;
    use std::vector;
    use std::bit_vector;
    use std::option::{Self, Option};
    use std::signer;
    use std::bcs;

    const E_INVALID_DATA_LENGTH: u64 = 1;
    const E_INVALID_SIGNER: u64 = 2;
    const E_DUPLICATE_SIGNER: u64 = 3;
    const E_INVALID_SIGNATURE_COUNT: u64 = 4;
    const E_INVALID_SIGNATURE: u64 = 5;
    const E_ALREADY_PROCESSED: u64 = 6;
    const E_NOT_OWNER: u64 = 7;
    const E_MALFORMED_SIGNATURE: u64 = 8;
    const E_FAULT_TOLERANCE_MUST_BE_POSITIVE: u64 = 9;
    const E_EXCESS_SIGNERS: u64 = 10;
    const E_INSUFFICIENT_SIGNERS: u64 = 11;
    const E_CALLBACK_DATA_NOT_CONSUMED: u64 = 12;
    const E_CANNOT_TRANSFER_TO_SELF: u64 = 13;
    const E_NOT_PROPOSED_OWNER: u64 = 14;
    const E_CONFIG_ID_NOT_FOUND: u64 = 15;
    const E_INVALID_REPORT_VERSION: u64 = 16;

    const MAX_ORACLES: u64 = 31;

    const APP_OBJECT_SEED: vector<u8> = b"FORWARDER";

    struct ConfigId has key, store, drop, copy {
        don_id: u32,
        config_version: u32
    }

    struct State has key {
        owner_address: address,
        pending_owner_address: address,
        extend_ref: ExtendRef,
        transfer_ref: TransferRef,

        // (don_id, config_version) => config
        configs: SmartTable<ConfigId, Config>,
        reports: SmartTable<vector<u8>, address>
    }

    struct Config has key, store, drop, copy {
        f: u8,
        // oracles: SimpleMap<address, Oracle>,
        oracles: vector<ed25519::UnvalidatedPublicKey>
    }

    #[event]
    struct ConfigSet has drop, store {
        don_id: u32,
        config_version: u32,
        f: u8,
        signers: vector<vector<u8>>
    }

    #[event]
    struct ReportProcessed has drop, store {
        receiver: address,
        workflow_execution_id: vector<u8>,
        report_id: u16
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

    inline fun assert_is_owner(state: &State, target_address: address) {
        assert!(
            state.owner_address == target_address,
            error::permission_denied(E_NOT_OWNER)
        );
    }

    fun init_module(publisher: &signer) {
        assert!(signer::address_of(publisher) == @platform, 1);

        let constructor_ref = object::create_named_object(publisher, APP_OBJECT_SEED);

        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let app_signer = &object::generate_signer(&constructor_ref);

        move_to(
            app_signer,
            State {
                owner_address: @owner,
                pending_owner_address: @0x0,
                configs: smart_table::new(),
                reports: smart_table::new(),
                extend_ref,
                transfer_ref
            }
        );
    }

    inline fun get_state_addr(): address {
        object::create_object_address(&@platform, APP_OBJECT_SEED)
    }

    public entry fun set_config(
        authority: &signer,
        don_id: u32,
        config_version: u32,
        f: u8,
        oracles: vector<vector<u8>>
    ) acquires State {
        let state = borrow_global_mut<State>(get_state_addr());

        assert_is_owner(state, signer::address_of(authority));

        assert!(f != 0, error::invalid_argument(E_FAULT_TOLERANCE_MUST_BE_POSITIVE));
        assert!(
            vector::length(&oracles) <= MAX_ORACLES,
            error::invalid_argument(E_EXCESS_SIGNERS)
        );
        assert!(
            vector::length(&oracles) >= 3 * (f as u64) + 1,
            error::invalid_argument(E_INSUFFICIENT_SIGNERS)
        );

        smart_table::upsert(
            &mut state.configs,
            ConfigId { don_id, config_version },
            Config {
                f,
                oracles: vector::map(
                    oracles,
                    |oracle| { ed25519::new_unvalidated_public_key_from_bytes(oracle) }
                )
            }
        );

        event::emit(
            ConfigSet { don_id, config_version, f, signers: oracles }
        );
    }

    public entry fun clear_config(
        authority: &signer, don_id: u32, config_version: u32
    ) acquires State {
        let state = borrow_global_mut<State>(get_state_addr());

        assert_is_owner(state, signer::address_of(authority));

        smart_table::remove(&mut state.configs, ConfigId { don_id, config_version });

        event::emit(
            ConfigSet { don_id, config_version, f: 0, signers: vector::empty() }
        );
    }

    use aptos_std::aptos_hash::blake2b_256;
    use aptos_std::ed25519;

    struct Signature has drop {
        public_key: ed25519::UnvalidatedPublicKey, // TODO: pass signer index rather than key to save on space and gas?
        sig: ed25519::Signature
    }

    public fun signature_from_bytes(bytes: vector<u8>): Signature {
        assert!(
            vector::length(&bytes) == 96,
            error::invalid_argument(E_MALFORMED_SIGNATURE)
        );
        let public_key =
            ed25519::new_unvalidated_public_key_from_bytes(vector::slice(&bytes, 0, 32));
        let sig = ed25519::new_signature_from_bytes(vector::slice(&bytes, 32, 96));
        Signature { sig, public_key }
    }

    inline fun transmission_id(
        receiver: address, workflow_execution_id: vector<u8>, report_id: u16
    ): vector<u8> {
        let id = bcs::to_bytes(&receiver);
        vector::append(&mut id, workflow_execution_id);
        vector::append(&mut id, bcs::to_bytes(&report_id));
        id
    }

    /// The dispatch call knows both storage and indirectly the callback, thus the separate module.
    fun dispatch(
        receiver: address, metadata: vector<u8>, data: vector<u8>
    ) {
        let meta = platform::storage::insert(receiver, metadata, data);
        aptos_framework::dispatchable_fungible_asset::derived_supply(meta);
        let obj_address =
            object::object_address<aptos_framework::fungible_asset::Metadata>(&meta);
        assert!(
            !platform::storage::storage_exists(obj_address),
            E_CALLBACK_DATA_NOT_CONSUMED
        );
    }

    entry fun report(
        transmitter: &signer,
        receiver: address,
        raw_report: vector<u8>,
        signatures: vector<vector<u8>>
    ) acquires State {
        let signatures = vector::map(
            signatures, |signature| signature_from_bytes(signature)
        );

        let (metadata, data) =
            validate_and_process_report(transmitter, receiver, raw_report, signatures);
        // NOTE: unable to catch failure here
        dispatch(receiver, metadata, data);
    }

    inline fun to_u16be(data: vector<u8>): u16 {
        // reverse big endian to little endian
        vector::reverse(&mut data);
        aptos_std::from_bcs::to_u16(data)
    }

    inline fun to_u32be(data: vector<u8>): u32 {
        // reverse big endian to little endian
        vector::reverse(&mut data);
        aptos_std::from_bcs::to_u32(data)
    }

    fun validate_and_process_report(
        transmitter: &signer,
        receiver: address,
        raw_report: vector<u8>,
        signatures: vector<Signature>
    ): (vector<u8>, vector<u8>) acquires State {
        let state = borrow_global_mut<State>(get_state_addr());

        // report_context = vector::slice(&raw_report, 0, 96);
        let report = vector::slice(&raw_report, 96, vector::length(&raw_report));

        // parse out report metadata
        // version | workflow_execution_id | timestamp | don_id | config_version | ...
        let report_version = *vector::borrow(&report, 0);
        assert!(report_version == 1, E_INVALID_REPORT_VERSION);

        let workflow_execution_id = vector::slice(&report, 1, 33);
        // _timestamp
        let don_id = vector::slice(&report, 37, 41);
        let don_id = to_u32be(don_id);
        let config_version = vector::slice(&report, 41, 45);
        let config_version = to_u32be(config_version);
        let report_id = vector::slice(&report, 107, 109);
        let report_id = to_u16be(report_id);
        let metadata = vector::slice(&report, 45, 109);
        let data = vector::slice(&report, 109, vector::length(&report));

        let config_id = ConfigId { don_id, config_version };
        assert!(smart_table::contains(&state.configs, config_id), E_CONFIG_ID_NOT_FOUND);
        let config = smart_table::borrow(&state.configs, config_id);

        // check if report was already delivered
        let transmission_id = transmission_id(receiver, workflow_execution_id, report_id);
        let processed = smart_table::contains(&state.reports, transmission_id);
        assert!(!processed, E_ALREADY_PROCESSED);

        let required_signatures = (config.f as u64) + 1;
        assert!(
            vector::length(&signatures) == required_signatures,
            error::invalid_argument(E_INVALID_SIGNATURE_COUNT)
        );

        // blake2b(report_context | report)
        let msg = blake2b_256(raw_report);

        let signed = bit_vector::new(vector::length(&config.oracles));

        vector::for_each_ref(
            &signatures,
            |signature| {
                let signature: &Signature = signature; // some compiler versions can't infer the type here

                let (valid, index) = vector::index_of(
                    &config.oracles, &signature.public_key
                );
                assert!(valid, error::invalid_argument(E_INVALID_SIGNER));

                // check for duplicate signers
                let duplicate = bit_vector::is_index_set(&signed, index);
                assert!(!duplicate, error::invalid_argument(E_DUPLICATE_SIGNER));
                bit_vector::set(&mut signed, index);

                let result =
                    ed25519::signature_verify_strict(
                        &signature.sig, &signature.public_key, msg
                    );
                assert!(result, error::invalid_argument(E_INVALID_SIGNATURE));
            }
        );

        // mark as delivered
        smart_table::add(
            &mut state.reports, transmission_id, signer::address_of(transmitter)
        );

        event::emit(ReportProcessed { receiver, workflow_execution_id, report_id });

        (metadata, data)
    }

    #[view]
    public fun get_transmission_state(
        receiver: address, workflow_execution_id: vector<u8>, report_id: u16
    ): bool acquires State {
        let state = borrow_global<State>(get_state_addr());
        let transmission_id = transmission_id(receiver, workflow_execution_id, report_id);

        return smart_table::contains(&state.reports, transmission_id)
    }

    #[view]
    public fun get_transmitter(
        receiver: address, workflow_execution_id: vector<u8>, report_id: u16
    ): Option<address> acquires State {
        let state = borrow_global<State>(get_state_addr());
        let transmission_id = transmission_id(receiver, workflow_execution_id, report_id);

        if (!smart_table::contains(&state.reports, transmission_id)) {
            return option::none()
        };
        option::some(*smart_table::borrow(&state.reports, transmission_id))
    }

    // Ownership functions

    #[view]
    public fun get_owner(): address acquires State {
        let state = borrow_global<State>(get_state_addr());
        state.owner_address
    }

    #[view]
    public fun get_config(don_id: u32, config_version: u32): Config acquires State {
        let state = borrow_global<State>(get_state_addr());
        let config_id = ConfigId { don_id, config_version };
        *smart_table::borrow(&state.configs, config_id)
    }

    public entry fun transfer_ownership(authority: &signer, to: address) acquires State {
        let state = borrow_global_mut<State>(get_state_addr());
        assert_is_owner(state, signer::address_of(authority));
        assert!(
            state.owner_address != to,
            error::invalid_argument(E_CANNOT_TRANSFER_TO_SELF)
        );

        state.pending_owner_address = to;

        event::emit(OwnershipTransferRequested { from: state.owner_address, to });
    }

    public entry fun accept_ownership(authority: &signer) acquires State {
        let state = borrow_global_mut<State>(get_state_addr());
        assert!(
            state.pending_owner_address == signer::address_of(authority),
            error::permission_denied(E_NOT_PROPOSED_OWNER)
        );

        let old_owner_address = state.owner_address;
        state.owner_address = state.pending_owner_address;
        state.pending_owner_address = @0x0;

        event::emit(
            OwnershipTransferred { from: old_owner_address, to: state.owner_address }
        );
    }

    #[test_only]
    public fun init_module_for_testing(publisher: &signer) {
        init_module(publisher);
    }

    #[test_only]
    public entry fun set_up_test(owner: &signer, publisher: &signer) {
        use aptos_framework::account::{Self};
        account::create_account_for_test(signer::address_of(owner));
        account::create_account_for_test(signer::address_of(publisher));

        init_module(publisher);
    }

    #[test_only]
    struct OracleSet has drop {
        don_id: u32,
        config_version: u32,
        f: u8,
        oracles: vector<vector<u8>>,
        signers: vector<ed25519::SecretKey>
    }

    #[test_only]
    fun generate_oracle_set(): OracleSet {
        let don_id = 0;
        let f = 1;

        let signers = vector[];
        let oracles = vector[];
        for (i in 0..31) {
            let (sk, pk) = ed25519::generate_keys();
            vector::push_back(&mut signers, sk);
            vector::push_back(&mut oracles, ed25519::validated_public_key_to_bytes(&pk));
        };
        OracleSet { don_id, config_version: 1, f, oracles, signers }
    }

    #[test_only]
    fun sign_report(
        config: &OracleSet, report: vector<u8>, report_context: vector<u8>
    ): vector<Signature> {
        // blake2b(report_context, report)
        let msg = report_context;
        vector::append(&mut msg, report);
        let msg = blake2b_256(msg);

        let signatures = vector[];
        let required_signatures = config.f + 1;
        for (i in 0..required_signatures) {
            let config_signer = vector::borrow(&config.signers, (i as u64));
            let public_key =
                ed25519::new_unvalidated_public_key_from_bytes(
                    *vector::borrow(&config.oracles, (i as u64))
                );
            let sig = ed25519::sign_arbitrary_bytes(config_signer, msg);
            vector::push_back(&mut signatures, Signature { sig, public_key });
        };
        signatures
    }

    #[test(owner = @owner, publisher = @platform)]
    public entry fun test_happy_path(owner: &signer, publisher: &signer) acquires State {
        set_up_test(owner, publisher);

        let config = generate_oracle_set();

        // configure DON
        set_config(
            owner,
            config.don_id,
            config.config_version,
            config.f,
            config.oracles
        );

        // generate report
        let version = 1;
        let timestamp: u32 = 1;
        let workflow_id =
            x"6d795f6964000000000000000000000000000000000000000000000000000000";
        let workflow_name = x"000000000000DEADBEEF";
        let workflow_owner = x"0000000000000000000000000000000000000051";
        let report_id = x"0001";
        let execution_id =
            x"6d795f657865637574696f6e5f69640000000000000000000000000000000000";
        let mercury_reports = vector[x"010203", x"aabbcc"];

        let report = vector[];
        // header
        vector::push_back(&mut report, version);
        vector::append(&mut report, execution_id);

        let bytes = bcs::to_bytes(&timestamp);
        // convert little-endian to big-endian
        vector::reverse(&mut bytes);
        vector::append(&mut report, bytes);

        let bytes = bcs::to_bytes(&config.don_id);
        // convert little-endian to big-endian
        vector::reverse(&mut bytes);
        vector::append(&mut report, bytes);

        let bytes = bcs::to_bytes(&config.config_version);
        // convert little-endian to big-endian
        vector::reverse(&mut bytes);
        vector::append(&mut report, bytes);

        // metadata
        vector::append(&mut report, workflow_id);
        vector::append(&mut report, workflow_name);
        vector::append(&mut report, workflow_owner);
        vector::append(&mut report, report_id);
        // report
        vector::append(&mut report, bcs::to_bytes(&mercury_reports));

        let report_context =
            x"a0b000000000000000000000000000000000000000000000000000000000000a0b000000000000000000000000000000000000000000000000000000000000a0b000000000000000000000000000000000000000000000000000000000000000";
        assert!(vector::length(&report_context) == 96, 1);

        let raw_report = vector[];
        vector::append(&mut raw_report, report_context);
        vector::append(&mut raw_report, report);

        // sign report
        let signatures = sign_report(&config, report, report_context);

        // call entrypoint
        validate_and_process_report(
            owner,
            signer::address_of(publisher),
            raw_report,
            signatures
        );
    }

    #[test(owner = @owner, publisher = @platform, new_owner = @0xbeef)]
    fun test_transfer_ownership_success(
        owner: &signer, publisher: &signer, new_owner: &signer
    ) acquires State {
        set_up_test(owner, publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(owner, signer::address_of(new_owner));
        accept_ownership(new_owner);

        assert!(get_owner() == signer::address_of(new_owner), 2);
    }

    #[test(owner = @owner, publisher = @platform, unknown_user = @0xbeef)]
    #[expected_failure(abort_code = 327687, location = platform::forwarder)]
    fun test_transfer_ownership_failure_not_owner(
        owner: &signer, publisher: &signer, unknown_user: &signer
    ) acquires State {
        set_up_test(owner, publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(unknown_user, signer::address_of(unknown_user));
    }

    #[test(owner = @owner, publisher = @platform)]
    #[expected_failure(abort_code = 65549, location = platform::forwarder)]
    fun test_transfer_ownership_failure_transfer_to_self(
        owner: &signer, publisher: &signer
    ) acquires State {
        set_up_test(owner, publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(owner, signer::address_of(owner));
    }

    #[test(owner = @owner, publisher = @platform, new_owner = @0xbeef)]
    #[expected_failure(abort_code = 327694, location = platform::forwarder)]
    fun test_transfer_ownership_failure_not_proposed_owner(
        owner: &signer, publisher: &signer, new_owner: &signer
    ) acquires State {
        set_up_test(owner, publisher);

        assert!(get_owner() == @owner, 1);

        transfer_ownership(owner, @0xfeeb);
        accept_ownership(new_owner);
    }
}
