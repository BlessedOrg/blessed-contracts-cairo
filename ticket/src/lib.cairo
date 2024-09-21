#[starknet::contract]
mod ERC1155EventTicket {
    // 🥱 Boring Cairo boilerplate...
    #[starknet::interface]
    trait IERC20<TContractState> {
        fn approve(ref self: TContractState, spender: ContractAddress, amount: u256);
        fn transferFrom(ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256);
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
    use starknet::syscalls::call_contract_syscall;

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
        pub royalties_map: LegacyMap<ContractAddress, u8>,
        pub royalties_receivers: LegacyMap<u32, ContractAddress>,
        pub royalties_receivers_count: u32,
        #[substorage(v0)]
        erc1155: ERC1155Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
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

    #[derive(Drop, starknet::Event)]
    struct TicketPurchase {
        buyer: ContractAddress,
        price: u256,
        token_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TicketRefund {
        buyer: ContractAddress,
        price: u256,
        token_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TokenListed {
        seller: ContractAddress,
        token_id: u256,
        price: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TokenDelisted {
        seller: ContractAddress,
        token_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct TokenFromListingPurchase {
        buyer: ContractAddress,
        seller: ContractAddress,
        token_id: u256,
        price: u256,
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
        TicketPurchase: TicketPurchase,
        TicketRefund: TicketRefund,
        TokenListed: TokenListed,
        TokenDelisted: TokenDelisted,
        TokenFromListingPurchase: TokenFromListingPurchase
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        ticket_price: u256,
        ticket_supply: u256,
        royalties_receivers: Array<(ContractAddress, u8)>,
        erc20_address: ContractAddress,
        ticket_type: felt252,
        event_start: u64,
        event_end: u64,
    ) {
        // assert(1 <= royalties && royalties <= 99, 'must be between 1 and 99');
        assert(event_start > get_block_timestamp(), 'event_start < now');
        assert(event_end > event_start, 'event_end < event_start');
        assert(royalties_receivers.len() == 0 || ticket_price > 10_u256, 'Price must be > 10 if royalties');

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
        // self.royalties.write(royalties);

        let mut total_royalties: u8 = 0;
        let mut count: u32 = 0;
        let mut royalties_receivers = royalties_receivers;
        loop {
            match royalties_receivers.pop_front() {
                Option::Some((address, percentage)) => {
                    total_royalties += percentage;
                    assert(total_royalties <= 99, 'Total royalties must be <= 99%');
                    self.royalties_map.write(address, percentage);
                    self.royalties_receivers.write(count, address);
                    count += 1;
                },
                Option::None => { break; },
            };
        };
        self.royalties_receivers_count.write(count);

        // dsadasdsa
        self.erc20_address.write(erc20_address);
        self.erc1155.initializer("");
        self.ownable.initializer(owner);

        let total_approval_amount = self.ticket_price.read() * self.ticket_supply.read();
        let mut erc20_address = self.erc20_address.read();
        IERC20::approve(
            ref erc20_address,
            starknet::get_contract_address(),
            total_approval_amount
        );

        // 🏗️ TODO: delete this ⬇️ it's for simpler testing
        // self.mint_ticket(owner);
        // self.mint_ticket(starknet::contract_address_const::<0x0384753535a8f4febe864e07d6c2bf0ea7be049cfaa1c5ebe9106b467b406a8e>());
    }

    // 🏗️ TODO: probably this will be for delete
    // #[external(v0)]
    // fn set_royalties(ref self: ContractState, royalties_receivers: Array<(ContractAddress, u8)>) {
    //     let mut total_royalties: u8 = 0;
    //     let mut count: u32 = 0;
    //     let mut royalties_receivers = royalties_receivers;
    //     loop {
    //         match royalties_receivers.pop_front() {
    //             Option::Some((address, percentage)) => {
    //                 total_royalties += percentage;
    //                 assert(total_royalties <= 99, 'Total royalties must be <= 99%');
    //                 self.royalties_map.write(address, percentage);
    //                 self.royalties_receivers.write(count, address);
    //                 count += 1;
    //             },
    //             Option::None => { break; },
    //         };
    //     };
    //     self.royalties_receivers_count.write(count);
    // }

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
            let current_token_id = self.next_token_id.read();
            self.ticket_balances.write(recipient, current_token_id);
            self.mint(recipient, current_token_id, 1, ArrayTrait::new().span());
            self.next_token_id.write(current_token_id + 1);
            self.emit(TicketPurchase { 
                buyer: recipient, 
                price: self.ticket_price.read(), 
                token_id: current_token_id
            });
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

    #[external(v0)]
    fn get(ref self: ContractState) {
        let caller = get_caller_address();
        let ticket_type = self.ticket_type.read();
        let caller_owned_token_id = self.ticket_balances.read(caller);
        assert(caller_owned_token_id == 0, 'You already have a ticket');
        let mut erc20_address = self.erc20_address.read();

        match ticket_type {
            EventType::Free => {
                self.mint_ticket(caller);
            },
            EventType::Refundable => {
                let caller_balance = IERC20::balance_of(@erc20_address, caller);
                assert(caller_balance >= self.ticket_price.read(), 'Insufficient balance');
                let allowed_amount = IERC20::allowance(@erc20_address, caller, starknet::get_contract_address());
                assert(allowed_amount >= self.ticket_price.read(), 'Insufficient allowance');
                
                IERC20::transferFrom(ref erc20_address, caller, starknet::get_contract_address(), self.ticket_price.read());
                self.mint_ticket(caller);
            },
            EventType::Paid => {
                let mut remaining_amount = self.ticket_price.read();
                let receivers_count = self.royalties_receivers_count.read();

                let mut i: u32 = 0;
                loop {
                    if i >= receivers_count {
                        break;
                    }
                    let receiver = self.royalties_receivers.read(i);
                    let royalty_percentage = self.royalties_map.read(receiver);
                    let royalty_amount = (self.ticket_price.read() * royalty_percentage.into()) / 100_u256;
                    if royalty_amount > 0 {
                        IERC20::transferFrom(ref erc20_address, caller, receiver, royalty_amount);
                        remaining_amount -= royalty_amount;
                    }
                    i += 1;
                };

                // Transfer remaining amount to owner
                if remaining_amount > 0 {
                    let owner = self.ownable.owner();
                    IERC20::transferFrom(ref erc20_address, caller, owner, remaining_amount);
                }

                self.mint_ticket(caller);
            }
        }
    }

    #[external(v0)]
    fn send(ref self: ContractState, to: ContractAddress) {
        self.mint_ticket(to)
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
                // assert(get_block_timestamp() > self.event_end.read(), 'Event has not ended yet');
                let caller = get_caller_address();
                let ticket_id_of_caller = self.ticket_balances.read(caller);
                assert(ticket_id_of_caller > 0, 'No ticket to refund');

                let ticket_price = self.ticket_price.read();
                let mut erc20_address = self.erc20_address.read();

                IERC20::transferFrom(ref erc20_address, starknet::get_contract_address(), caller, ticket_price);
                self.emit(TicketRefund { 
                    buyer: get_caller_address(), 
                    price: self.ticket_price.read(), 
                    token_id: ticket_id_of_caller
                });
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
        assert(self.erc1155.balance_of(caller, token_id) > 0, 'Not the token owner');
        let (listed_token_id, _) = self.ticket_listings.read(caller);
        assert(listed_token_id == 0, 'Token already listed');
        assert(price > 0, 'Price must be greater than zero');
        assert(get_block_timestamp() < self.event_start.read(), 'Event has already started');

        self.erc1155.set_approval_for_all(starknet::get_contract_address(), true);
        self.ticket_listings.write(caller, (token_id, price));
        self.emit(TokenListed { seller: caller, token_id: token_id, price: price });
    }

    #[external(v0)]
    fn delist(ref self: ContractState, token_id: u256) {
        let caller = get_caller_address();
        let (listed_token_id, _) = self.ticket_listings.read(caller);
        assert(listed_token_id == token_id, 'Token not listed ');

        self.ticket_listings.write(caller, (0, 0)); // Reset the listing
        self.erc1155.set_approval_for_all(starknet::get_contract_address(), false);
        self.emit(TokenDelisted { seller: caller, token_id: token_id });
    }

    #[external(v0)]
    fn buy(ref self: ContractState, seller: ContractAddress, token_id: u256) {
        // before calling this, user needs to approve this contract to spend their ERC20 tokens
        let buyer = get_caller_address();
        let (listed_token_id, price) = self.ticket_listings.read(seller);
        assert(listed_token_id == token_id, 'Token not listed');
        assert(buyer != seller, 'Cannot buy your own token');
        assert(get_block_timestamp() < self.event_start.read(), 'Event has already started');
        
        // Check buyer's balance and allowance
        let mut erc20_address = self.erc20_address.read();
        let buyer_balance = IERC20::balance_of(@erc20_address, buyer);
        assert(buyer_balance >= price, 'Insufficient balance of ERC20');
        let allowed_amount = IERC20::allowance(@erc20_address, buyer, starknet::get_contract_address());
        assert(allowed_amount >= price, 'Insufficient allowance of ERC20');
        
        // Transfer the full price from the buyer to this contract
        IERC20::transferFrom(ref erc20_address, buyer, starknet::get_contract_address(), price);
        
        // Transfer the royalties to the contract owner
        let owner = self.ownable.owner();
        let royalties_amount = (price * self.royalties.read().into()) / 100_u256;
        IERC20::transferFrom(ref erc20_address, starknet::get_contract_address(), owner, royalties_amount);

        // Transfer the remaining amount to the seller
        let seller_amount = price - royalties_amount;
        IERC20::transferFrom(ref erc20_address, starknet::get_contract_address(), seller, seller_amount);

        // Transfer the token to the buyer
        // Replace the direct call with a low-level call
        let contract_address = starknet::get_contract_address();
        let calldata = array![
            seller.into(),
            buyer.into(),
            token_id.low.into(),
            token_id.high.into(),
            1.into(),
            0.into(),
            0.into(), // data length (empty array)
        ];
        let result = starknet::syscalls::call_contract_syscall(
            contract_address,
            selector!("safeTransferFrom"),
            calldata.span()
        ).unwrap();
        assert(result.len() == 0, 'Transfer failed');
        // self.erc1155.safe_transfer_from(seller, buyer, token_id, 1, ArrayTrait::new().span());

        self.ticket_balances.write(seller, 0);
        self.ticket_balances.write(buyer, token_id);

        self.ticket_listings.write(seller, (0, 0)); // Reset the listing

        self.emit(TokenFromListingPurchase { buyer, seller, token_id, price });
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
    fn get_wallet_token_id(self: @ContractState, wallet: ContractAddress) -> u256 {
        self.ticket_balances.read(wallet)
    }

    #[external(v0)]
    fn get_listing_of_wallet(self: @ContractState, wallet: ContractAddress) -> (u256, u256) {
        let (token_id, price) = self.ticket_listings.read(wallet);
        (token_id, price)
    }

    #[external(v0)]
    fn get_royalties(self: @ContractState) -> Array<(ContractAddress, u8)> {
        let mut result = ArrayTrait::new();
        let receivers_count = self.royalties_receivers_count.read();
        let mut i: u32 = 0;
        loop {
            if i >= receivers_count {
                break;
            }
            let receiver = self.royalties_receivers.read(i);
            let percentage = self.royalties_map.read(receiver);
            result.append((receiver, percentage));
            i += 1;
        };
        result
    }
}
