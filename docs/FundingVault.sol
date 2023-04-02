// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

interface IFundingVault {
  function notifyPledgeTransfer(uint64 pledgeId) external;
}

interface IFundingVaultToken is IERC721Enumerable {
  function pledgeOwner(uint64 tokenId) external view returns (address);
  function pledgeUpdate(uint64 tokenId, address targetAddr) external;
}

contract FundingVaultToken is ERC721Enumerable, IFundingVaultToken {
  address private _fundingVault;

  constructor(address fundingVault) ERC721("Funding Pledge", "FundPlg") {
    _fundingVault = fundingVault;
  }

  receive() external payable {
    if(msg.value > 0) {
      (bool sent, ) = payable(_fundingVault).call{value: msg.value}("");
      require(sent, "failed to forward ether");
    }
  }

  function getVault() public view returns (address) {
    return _fundingVault;
  }

  function _baseURI() internal view override returns (string memory) {
    return string(abi.encodePacked("https://dev.pk910.de/ethvault?c=", Strings.toString(block.chainid), "&v=",  Strings.toHexString(uint160(_fundingVault), 20), "&p="));
  }

  function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize) internal virtual override {
    super._beforeTokenTransfer(from, to, tokenId, batchSize);

    IFundingVault(_fundingVault).notifyPledgeTransfer(uint64(tokenId));
  }

  function pledgeOwner(uint64 tokenId) public view returns (address) {
    return _ownerOf(tokenId);
  }

  function pledgeUpdate(uint64 tokenId, address targetAddr) public {
    require(_msgSender() == _fundingVault, "not vault contract");

    if(targetAddr != address(0)) {
      if(!_exists(tokenId)) {
        _safeMint(targetAddr, tokenId);
      }
      else if(_ownerOf(tokenId) != targetAddr) {
        _safeTransfer(_ownerOf(tokenId), targetAddr, tokenId, "");
      }
    }
    else if(_exists(tokenId)) {
      _burn(tokenId);
    }
  }

}

import "@openzeppelin/contracts/access/AccessControl.sol";


struct Pledge {
  uint64 claimTime;
  uint64 claimInterval;
  uint128 claimLimit;
}

contract FundingVaultStorage {
  // slot 0x01
  address internal _vaultTokenAddr;

  // slot 0x02
  uint64 internal _pledgeIdCounter;
  uint64 internal _claimTransferLockTime;

  // mappings
  mapping(uint64 => Pledge) internal _pledges;
  mapping(uint64 => uint64) internal _pledgeClaimLock;
}

contract FundingVault is FundingVaultStorage, IFundingVault, AccessControl {
  bytes32 public constant PLEDGE_MANAGER_ROLE = keccak256("PLEDGE_MANAGER_ROLE");

  event PledgeLocked(uint64 indexed pledgeId, uint64 lockTime, uint64 lockTimeout);
  event PledgeUpdate(uint64 indexed pledgeId, uint128 amount, uint64 interval);
  event FundClaim(uint64 indexed pledgeId, address indexed to, uint256 amount, uint64 pledgeTimeUsed);
  
  constructor() {
    _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    _grantRole(PLEDGE_MANAGER_ROLE, _msgSender());

    _vaultTokenAddr = address(new FundingVaultToken(address(this)));

    _pledgeIdCounter = 1;
    _claimTransferLockTime = 86400 * 2; // 2 days
  }

  receive() external payable {
  }


  //## Admin configuration / rescue functions

  function rescueCall(address addr, uint256 amount, bytes calldata data) public onlyRole(DEFAULT_ADMIN_ROLE) {
    uint balance = address(this).balance;
    require(balance >= amount, "amount exceeds wallet balance");

    (bool sent, ) = payable(addr).call{value: amount}(data);
    require(sent, "call failed");
  }

  function setClaimTransferLockTime(uint64 lockTime) public onlyRole(DEFAULT_ADMIN_ROLE) {
    _claimTransferLockTime = lockTime;
  }

  
  //## Internal helper functions

  function _ownerOf(uint64 tokenId) internal view returns (address) {
    return IFundingVaultToken(_vaultTokenAddr).pledgeOwner(tokenId);
  }

  function _getTime() internal view returns (uint64) {
    return uint64(block.timestamp);
  }

  function _calculateClaim(uint64 pledgeId, uint256 requestAmount) internal view returns (uint64, uint64, uint256) {
    Pledge memory pledge = _pledges[pledgeId];
    
    uint256 claimLimit = pledge.claimLimit * 1 ether;
    if(requestAmount > claimLimit) {
      requestAmount = claimLimit;
    }
    if(requestAmount == 0 && claimLimit == 0) {
        // dont allow unlimited claim!
        requestAmount = 1 ether;
    }

    uint64 time = _getTime();
    uint64 claimTime;
    uint64 usedTime;
    uint256 claimAmount;
    if(_pledgeClaimLock[pledgeId] > time) {
      // pledge locked
      claimTime = pledge.claimTime;
      usedTime = 0;
      claimAmount = 0;
    }
    else if(pledge.claimInterval == 0) {
      // no time restriction
      claimTime = time;
      usedTime = 0;
      claimAmount = requestAmount;
    }
    else {
      uint64 baseClaimTime = pledge.claimTime;
      uint64 availableTime = time - baseClaimTime;
      if(availableTime > pledge.claimInterval) {
        availableTime = pledge.claimInterval;
        baseClaimTime = time - pledge.claimInterval;
      }

      claimAmount = claimLimit * availableTime / pledge.claimInterval;
      if(requestAmount != 0 && requestAmount < claimAmount) {
        // partial claim
        usedTime = uint64(requestAmount * pledge.claimInterval / claimLimit) + 1;
        if(usedTime > availableTime) {
          usedTime = availableTime;
        }

        claimTime = baseClaimTime + usedTime;
        claimAmount = requestAmount;
      }
      else {
        usedTime = availableTime;
        claimTime = time;
      }
    }

    return (claimTime, usedTime, claimAmount);
  }


  //## Public view functions

  function getVaultToken() public view returns (address) {
    return _vaultTokenAddr;
  }

  function getPledges() public view returns (Pledge[] memory) {
    IFundingVaultToken vaultToken = IFundingVaultToken(_vaultTokenAddr);
    uint64 pledgeCount = uint64(vaultToken.totalSupply());
    Pledge[] memory pledges = new Pledge[](pledgeCount);
    for(uint64 pledgeIdx = 0; pledgeIdx < pledgeCount; pledgeIdx++) {
      uint64 pledgeId = uint64(vaultToken.tokenByIndex(pledgeIdx));
      pledges[pledgeIdx] = _pledges[pledgeId];
    }
    return pledges;
  }

  function getPledge(uint64 pledgeId) public view returns (Pledge memory) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    return _pledges[pledgeId];
  }

  function getPledgeLockTime(uint32 pledgeId) public view returns (uint64) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    if(_pledgeClaimLock[pledgeId] > uint64(block.timestamp)) {
      return _pledgeClaimLock[pledgeId] - uint64(block.timestamp);
    }
    else {
      return 0;
    }
  }

  function getClaimableBalance() public view returns (uint256) {
    uint256 claimableAmount = 0;
    IFundingVaultToken vaultToken = IFundingVaultToken(_vaultTokenAddr);

    uint64 pledgeCount = uint64(vaultToken.balanceOf(_msgSender()));
    for(uint64 pledgeIdx = 0; pledgeIdx < pledgeCount; pledgeIdx++) {
      uint64 pledgeId = uint64(vaultToken.tokenOfOwnerByIndex(_msgSender(), pledgeIdx));
      claimableAmount += _claimableBalance(pledgeId);
    }
    return claimableAmount;
  }

  function getClaimableBalance(uint64 pledgeId) public view returns (uint256) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    return _claimableBalance(pledgeId);
  }

  function _claimableBalance(uint64 pledgeId) internal view returns (uint256) {
    (, , uint256 claimAmount) = _calculateClaim(pledgeId, 0);
    return claimAmount;
  }


  //## Pledge managemnet functions (Plege Manager)

  function createPledge(address addr, uint128 amount, uint64 interval) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_vaultTokenAddr != address(0), "not initialized");
    uint64 pledgeId = _pledgeIdCounter++;

    _pledges[pledgeId] = Pledge({
      claimTime: _getTime() - interval,
      claimInterval: interval,
      claimLimit: amount
    });

    IFundingVaultToken(_vaultTokenAddr).pledgeUpdate(pledgeId, addr);

    emit PledgeUpdate(pledgeId, amount, interval);
  }

  function updatePledge(uint64 pledgeId, uint128 amount, uint64 interval) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");

    _pledges[pledgeId].claimInterval = interval;
    _pledges[pledgeId].claimLimit = amount;

    emit PledgeUpdate(pledgeId, amount, interval);
  }

  function transferPledge(uint64 pledgeId, address addr) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    IFundingVaultToken(_vaultTokenAddr).pledgeUpdate(pledgeId, addr);
  }

  function removePledge(uint64 pledgeId) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");

    IFundingVaultToken(_vaultTokenAddr).pledgeUpdate(pledgeId, address(0));
    delete _pledges[pledgeId];
  }

  function lockPledge(uint64 pledgeId, uint64 lockTime) public {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    require(
      _msgSender() == _vaultTokenAddr || 
      _msgSender() == _ownerOf(pledgeId) || 
      hasRole(PLEDGE_MANAGER_ROLE, _msgSender())
    , "not pledge owner or manager");

    _lockPledge(pledgeId, lockTime);
  }

  function notifyPledgeTransfer(uint64 pledgeId) public {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    require(_msgSender() == _vaultTokenAddr, "not pledge token contract");

    _lockPledge(pledgeId, _claimTransferLockTime);
  }

  function _lockPledge(uint64 pledgeId, uint64 lockTime) internal {
    uint64 lockTimeout = _getTime() + lockTime;
    if(lockTimeout > _pledgeClaimLock[pledgeId] || hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
      _pledgeClaimLock[pledgeId] = lockTimeout;
    }
    else {
      lockTime = 0;
      lockTimeout = _pledgeClaimLock[pledgeId];
    }
    emit PledgeLocked(pledgeId, lockTime, lockTimeout);
  }

  
  //## Public claim functions

  function claim(uint256 amount) public returns (uint256) {
    uint256 claimAmount = _claimFrom(_msgSender(), amount, _msgSender());
    if(amount > 0) {
      require(claimAmount == amount, "claim failed");
    }
    else {
      require(claimAmount > 0, "claim failed");
    }
    return claimAmount;
  }

  function claim(uint64 pledgeId, uint256 amount) public returns (uint256) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    require(_ownerOf(pledgeId) == _msgSender(), "not owner of this pledge");

    uint256 claimAmount = _claim(pledgeId, amount, _msgSender());
    if(amount > 0) {
      require(claimAmount == amount, "claim failed");
    }
    else {
      require(claimAmount > 0, "claim failed");
    }
    return claimAmount;
  }

  function claimTo(uint256 amount, address target) public returns (uint256) {
    uint256 claimAmount = _claimFrom(_msgSender(), amount, target);
    if(amount > 0) {
      require(claimAmount == amount, "claim failed");
    }
    else {
      require(claimAmount > 0, "claim failed");
    }
    return claimAmount;
  }

  function claimTo(uint64 pledgeId, uint256 amount, address target) public returns (uint256) {
    require(_pledges[pledgeId].claimTime > 0, "pledge not found");
    require(_ownerOf(pledgeId) == _msgSender(), "not owner of this pledge");

    uint256 claimAmount = _claim(pledgeId, amount, target);
    if(amount > 0) {
      require(claimAmount == amount, "claim failed");
    }
    else {
      require(claimAmount > 0, "claim failed");
    }
    return claimAmount;
  }

  function _claimFrom(address owner, uint256 amount, address target) internal returns (uint256) {
    uint256 claimAmount = 0;
    IFundingVaultToken vaultToken = IFundingVaultToken(_vaultTokenAddr);

    uint64 pledgeCount = uint64(vaultToken.balanceOf(owner));
    for(uint64 pledgeIdx = 0; pledgeIdx < pledgeCount; pledgeIdx++) {
      uint64 pledgeId = uint64(vaultToken.tokenOfOwnerByIndex(owner, pledgeIdx));
      uint256 claimed = _claim(pledgeId, amount, target);
      claimAmount += claimed;
      if(amount > 0) {
        if(amount == claimed) {
          break;
        }
        else {
          amount -= claimed;
        }
      }
    }
    return claimAmount;
  }

  function _claim(uint64 pledgeId, uint256 amount, address target) internal returns (uint256) {
    (uint64 newClaimTime, uint64 usedClaimTime, uint256 claimAmount) = _calculateClaim(pledgeId, amount);
    if(claimAmount == 0) {
      return 0;
    }

    _pledges[pledgeId].claimTime = newClaimTime;

    // send claim amount to target
    (bool sent, ) = payable(target).call{value: claimAmount}("");
    require(sent, "failed to send ether");

    emit FundClaim(pledgeId, target, claimAmount, usedClaimTime);

    return claimAmount;
  }

}
