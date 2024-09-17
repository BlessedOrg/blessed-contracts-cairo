use starknet::{ContractAddress};
#[starknet::interface]
trait IERC1155<TContractState> {
    fn balanceOf(self: @TContractState, account: ContractAddress, tokenId: u256) -> u256;
}

#[starknet::contract]
mod EntraceCheckerContract {
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use core::traits::Into;
    use core::array::ArrayTrait;
    use openzeppelin::access::ownable::interface::IOwnable;
    use openzeppelin::access::ownable::OwnableComponent;
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use starknet::syscalls::call_contract_syscall;
    use super::IERC1155;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        entries: LegacyMap::<ContractAddress, u64>,
        erc1155: ContractAddress,
        isEventFinished: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        NewEntry: NewEntry,
    }

    #[derive(Drop, starknet::Event)]
    struct NewEntry {
        address: ContractAddress,
        timestamp: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, erc1155: ContractAddress, owner: ContractAddress) {
        self.ownable.initializer(owner);
        self.erc1155.write(erc1155);
    }

    #[abi(embed_v0)]
    impl EntraceCheckerContractEntries of super::IEntraceCheckerContractEntries<ContractState> {
        fn entry(ref self: ContractState, tokenId: u256) {
            // check is entry exist
            let caller = get_caller_address();
            assert(self.entries.read(caller) == 0, 'Caller already has an entry');

            // check is caller owner of ticket
            let balance = self.check_balance(caller, tokenId);
            assert(balance > 0, 'Insufficient balance');

            let timestamp = get_block_timestamp();
            self.entries.write(caller, timestamp);

            self.emit(Event::NewEntry(NewEntry { address: caller, timestamp: timestamp }));
        }

        fn closeEvent(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.isEventFinished.write(true);
        }

        fn get_entry(self: @ContractState, address: ContractAddress) -> u64 {
            self.entries.read(address)
        }
        fn get_owner_address(self: @ContractState) -> ContractAddress {
            self.ownable.owner()
        }
        fn get_erc1155(self: @ContractState) -> ContractAddress {
            self.erc1155.read()
        }
    }


    #[generate_trait]
    impl PrivateFunctions of PrivateFunctionsTrait {
        fn check_balance(self: @ContractState, caller: ContractAddress, tokenId: u256) -> u256 {
            let mut calldata = ArrayTrait::new();
            let caller_felt: felt252 = caller.into();

            calldata.append(caller_felt);
            calldata.append(tokenId.low.into());
            calldata.append(tokenId.high.into());

            let result = call_contract_syscall(
                self.erc1155.read(), selector!("balanceOf"), calldata.span()
            )
                .unwrap();

            let low: felt252 = *result.at(0);
            let high: felt252 = *result.at(1);
            u256 { low: low.try_into().unwrap(), high: high.try_into().unwrap() }
        }
    }
}

#[starknet::interface]
trait IEntraceCheckerContractEntries<TContractState> {
    fn entry(ref self: TContractState, tokenId: u256);
    fn get_entry(self: @TContractState, address: ContractAddress) -> u64;
    fn get_erc1155(self: @TContractState) -> ContractAddress;
    fn get_owner_address(self: @TContractState) -> ContractAddress;
    fn closeEvent(ref self: TContractState);
}
