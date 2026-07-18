// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {D17Locker} from "./D17Locker.sol";

interface ID17LockerRegistry {
    function weth() external view returns (address);
    function registerLockerFor(address lockerOwner, address locker) external;
}

contract D17LockerFactory {
    address public immutable d17Factory;

    event LockerCreated(address indexed owner, address indexed locker);

    constructor(address d17Factory_) {
        require(d17Factory_ != address(0), "FACTORY_ZERO");
        require(d17Factory_.code.length > 0, "FACTORY_NO_CODE");
        d17Factory = d17Factory_;
    }

    function createLockerFor(address lockerOwner) external returns (address locker) {
        require(lockerOwner != address(0), "OWNER_ZERO");
        require(msg.sender == lockerOwner, "ONLY_SELF");
        ID17LockerRegistry registry = ID17LockerRegistry(d17Factory);
        locker = address(new D17Locker(lockerOwner, d17Factory, registry.weth()));
        registry.registerLockerFor(lockerOwner, locker);
        emit LockerCreated(lockerOwner, locker);
    }
}
