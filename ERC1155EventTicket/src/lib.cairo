#[starknet::contract]
mod ERC1155EventTicket {
    // 🥱 Boring Cairo boilerplate...
    #[starknet::interface]
    trait IERC20<TContractState> {
        fn approve(ref self: TContractState, spender: ContractAddress, amount: u256);
        fn transferFrom( ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256);
        fn balance_of(self: @TContractState, owner: ContractAddress) -> u256;
        fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;

    }
    impl IERC20Impl of IERC20<ContractAddress> {
        fn approve(ref self: ContractAddress, spender: ContractAddress, amount: u256) {
            IERC20Dispatcher { contract_address: self }.approve(spender, amount);
        }
        fn transferFrom(ref self: ContractAddress, sender: ContractAddress, recipient: ContractAddress, amount: u256) {
            IERC20Dispatcher { contract_address: self }.transferFrom(sender, recipient, amount);
        }
				fn balance_of(self: @ContractAddress, owner: ContractAddress) -> u256 {
            IERC20Dispatcher { contract_address: *self }.balance_of(owner)
        }
        fn allowance(self: @ContractAddress, owner: ContractAddress, spender: ContractAddress) -> u256 {
            IERC20Dispatcher { contract_address: *self }.allowance(owner, spender)
        }
    }
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::security::pausable::PausableComponent;
    use openzeppelin::token::erc1155::ERC1155Component;
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;

    component!(path: ERC1155Component, storage: erc1155, event: ERC1155Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl ERC1155MixinImpl = ERC1155Component::ERC1155MixinImpl<ContractState>;
    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;

    impl ERC1155InternalImpl = ERC1155Component::InternalImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    impl ERC1155HooksImpl of ERC1155Component::ERC1155HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC1155Component::ComponentState<ContractState>,
            from: ContractAddress,
            to: ContractAddress,
            token_ids: Span<u256>,
            values: Span<u256>,
        ) {
            let contract_state = ERC1155Component::HasComponent::get_contract(@self);
            contract_state.pausable.assert_not_paused();
        }

        fn after_update(
            ref self: ERC1155Component::ComponentState<ContractState>,
            from: ContractAddress,
            to: ContractAddress,
            token_ids: Span<u256>,
            values: Span<u256>,
        ) {}
    }

    // 🥩 Actual Contract's logic
    #[storage]
    struct Storage {
        pub ticket_price: u256,
        pub ticket_balances: LegacyMap<ContractAddress, u256>,
        pub ticket_type: EventType,
        pub ticket_supply: u256,
        pub ticket_listings: LegacyMap<ContractAddress, (u256, u256)>,
        pub royalties: u8,
        pub erc20_address: ContractAddress,
        pub next_token_id: u256,
        pub event_start: u64,
        pub event_end: u64,
        #[substorage(v0)]
        erc1155: ERC1155Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

		#[derive(Copy, Drop, Serde, starknet::Store)]
		 enum EventType {
		     Free,
		     Refundable,
		     Paid,
		 }

    #[derive(Drop)]
    struct Listing {
        token_id: u256,
        price: u256,
        is_active: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC1155Event: ERC1155Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        ticket_price: u256,
        ticket_supply: u256,
        royalties: u8,
        erc20_address: ContractAddress,
        ticket_type: felt252,
        event_start: u64,
        event_end: u64,
    ) {
        assert(1 <= royalties && royalties <= 99, 4); // Error code 4: Invalid royalties percentage
        assert(event_start > get_block_timestamp(), 'event_start < now');
        assert(event_end > event_start, 'event_end < event_start');

        let ticket_type_value =
        if ticket_type == 'free' {
            EventType::Free
        } else if ticket_type == 'refundable' {
            EventType::Refundable
        } else if ticket_type == 'paid' {
            EventType::Paid
        } else {
            let mut error_msg = ArrayTrait::new();
            error_msg.append('free | refundable | paid');
            panic(error_msg)
        };
        self.ticket_type.write(ticket_type_value);
        self.event_start.write(event_start);
        self.event_end.write(event_end);
        self.next_token_id.write(1);
        self.ticket_price.write(ticket_price);
        self.ticket_supply.write(ticket_supply);
        self.royalties.write(royalties);
        self.erc20_address.write(erc20_address);
        self.erc1155.initializer("");
        self.ownable.initializer(owner);
    }

    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn mint(
            ref self: ContractState,
            account: ContractAddress,
            token_id: u256,
            value: u256,
            data: Span<felt252>,
        ) {
            self.erc1155.mint_with_acceptance_check(account, token_id, value, data);
        }

        fn mint_ticket(ref self: ContractState, recipient: ContractAddress) {
            self.ticket_balances.write(recipient, 1);
            let current_token_id = self.next_token_id.read();
            self.mint(recipient, current_token_id, 1, ArrayTrait::new().span());
            self.next_token_id.write(current_token_id + 1);
        }

        #[external(v0)]
        fn batch_mint(
            ref self: ContractState,
            account: ContractAddress,
            token_ids: Span<u256>,
            values: Span<u256>,
            data: Span<felt252>,
        ) {
            self.ownable.assert_only_owner();
            self.erc1155.batch_mint_with_acceptance_check(account, token_ids, values, data);
        }

        #[external(v0)]
        fn batchMint(
            ref self: ContractState,
            account: ContractAddress,
            tokenIds: Span<u256>,
            values: Span<u256>,
            data: Span<felt252>,
        ) {
            self.batch_mint(account, tokenIds, values, data);
        }
    }

    fn get_ticket(ref self: ContractState) {
        let caller = get_caller_address();
        let ticket_type = self.ticket_type.read();
        let current_balance = self.ticket_balances.read(caller);
        assert(current_balance == 0, 'Already has a ticket');

        match ticket_type {
            EventType::Free => {
                self.mint_ticket(caller);
            },
            EventType::Refundable | EventType::Paid => {
                let mut erc20_address = self.erc20_address.read();
                let caller_balance = IERC20::balance_of(@erc20_address, caller);
                assert(caller_balance >= self.ticket_price.read(), 'Insufficient balance');
                let allowed_amount = IERC20::allowance(@erc20_address, caller, starknet::get_contract_address());
                assert(allowed_amount >= self.ticket_price.read(), 'Insufficient allowance');
                IERC20::transferFrom(ref erc20_address, caller, self.ownable.owner(), self.ticket_price.read());
                self.mint_ticket(caller);
            },
        }
    }

    #[external(v0)]
    fn get_ticket_type_felt252(self: @ContractState) -> felt252 {
        match self.ticket_type.read() {
            EventType::Free => 'free',
            EventType::Refundable => 'refundable',
            EventType::Paid => 'paid',
        }
    }

    #[external(v0)]
    fn get_ticket_type_enum(self: @ContractState) -> EventType {
        self.ticket_type.read()
    }

    #[external(v0)]
    fn refund(ref self: ContractState) {
        let ticket_type = self.ticket_type.read();
        match ticket_type {
            EventType::Refundable => {
                assert(get_block_timestamp() > self.event_end.read(), 'Event has not ended yet');
	                  let caller = get_caller_address();
	                  let ticket_balance = self.ticket_balances.read(caller);
	                  assert(ticket_balance > 0, 'No ticket to refund');

	                  let ticket_price = self.ticket_price.read();
	                  let mut erc20_address = self.erc20_address.read();

	                  IERC20::transferFrom(ref erc20_address, self.ownable.owner(), caller, ticket_price);
	                  // Emit a refund event (you'll need to define this event)
	                  // self.emit(RefundEvent { user: caller, amount: ticket_price });
            },
            EventType::Free | EventType::Paid => {
               let mut error_msg = ArrayTrait::new();
                error_msg.append('Cannot refund this event');
                panic(error_msg)
            }
        }
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, to: ContractAddress, amount: u256) {
        let caller = get_caller_address();
        let mut array: Array<felt252> = ArrayTrait::new();
        let span = array.span();
        self.erc1155.safe_transfer_from(caller, to, 0, amount, span);
    }

    #[external(v0)]
    fn pause(ref self: ContractState) {
        self.ownable.assert_only_owner();
        self.pausable.pause();
    }

    #[external(v0)]
    fn unpause(ref self: ContractState) {
        self.ownable.assert_only_owner();
        self.pausable.unpause();
    }

    #[external(v0)]
    fn set_base_uri(ref self: ContractState, base_uri: ByteArray) {
        self.ownable.assert_only_owner();
        self.erc1155._set_base_uri(base_uri);
    }

    #[external(v0)]
    fn list(ref self: ContractState, token_id: u256, price: u256) {
        let caller = get_caller_address();
        // Check if the caller owns the token
        assert(self.erc1155.balance_of(caller, token_id) > 0, 2); // Error code 2: Not the token owner

        // Approve the contract to transfer the token
        self.erc1155.set_approval_for_all(caller, true);

        // List the token
        self.ticket_listings.write(caller, (token_id, price));
    }

    #[external(v0)]
    fn delist(ref self: ContractState, token_id: u256) {
        let caller = get_caller_address();
        // Check if the token is listed
        let (listed_token_id, _) = self.ticket_listings.read(caller);
        assert(listed_token_id == token_id, 3); // Error code 3: Token not listed or not owned by caller

        // Delist the token
        self.ticket_listings.write(caller, (0, 0)); // Reset the listing
    }

    #[external(v0)]
    fn buy(ref self: ContractState, seller: ContractAddress, token_id: u256, mut erc20_address: ContractAddress) {
        let buyer = get_caller_address();
        // Check if the token is listed
        let (listed_token_id, price) = self.ticket_listings.read(seller);
        assert(listed_token_id == token_id, 3); // Error code 3: Token not listed or incorrect token ID

        // Calculate the royalties amount
        let royalties_percentage = self.royalties.read();
        let royalties_amount = (price * royalties_percentage.into()) / 100_u256;

        // 🏗️ TODO: move it to the seperate function to safely call transferFrom | Approve the
        // contract to spend the buyer's tokens IERC20::approve(ref erc20_address,
        // starknet::get_contract_address(), price);

        // Transfer the token price from the buyer to the contract
        IERC20::transferFrom(ref erc20_address, buyer, seller, price);

        // Transfer the royalties to the contract owner
        let owner = self.ownable.owner();
        IERC20::transferFrom(
            ref erc20_address, starknet::get_contract_address(), owner, royalties_amount
        );

        // Transfer the remaining amount to the seller
        let seller_amount = price - royalties_amount;
        IERC20::transferFrom(
            ref erc20_address, starknet::get_contract_address(), seller, seller_amount
        );

        // Transfer the token to the buyer
        self.erc1155.safe_transfer_from(seller, buyer, token_id, 1, ArrayTrait::new().span());

        // Delist the token
        self.ticket_listings.write(seller, (0, 0)); // Reset the listing
    }

    #[external(v0)]
    fn get_erc20_contract_address(self: @ContractState) -> ContractAddress {
        self.erc20_address.read()
    }

    #[external(v0)]
    fn get_ticket_price(self: @ContractState) -> u256 {
        self.ticket_price.read()
    }

    #[external(v0)]
    fn get_ticket_supply(self: @ContractState) -> u256 {
        self.ticket_supply.read()
    }

    #[external(v0)]
    fn get_royalties(self: @ContractState) -> u8 {
        self.royalties.read()
    }

    #[external(v0)]
    fn get_wallet_balance(self: @ContractState, wallet: ContractAddress) -> u256 {
        self.ticket_balances.read(wallet)
    }
    // add getter for specified listing
}
