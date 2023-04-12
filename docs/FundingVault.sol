// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

interface IFundingVault {
  function notifyGrantTransfer(uint64 grantId) external;
}

interface IFundingVaultToken is IERC721Enumerable {
  function tokenUpdate(uint64 tokenId, address targetAddr) external;
}

contract FundingVaultToken is ERC721Enumerable, IFundingVaultToken {
  address private _fundingVault;

  constructor(address fundingVault) ERC721("FundingVault Grant", "FVGrant") {
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

    IFundingVault(_fundingVault).notifyGrantTransfer(uint64(tokenId));
  }

  function tokenUpdate(uint64 tokenId, address targetAddr) public {
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


struct Grant {
  uint64 claimTime;
  uint64 claimInterval;
  uint128 claimLimit;
}

contract FundingVaultStorage {
  // slot 0x01
  address internal _vaultTokenAddr;

  // slot 0x02
  uint64 internal _grantIdCounter = 1;
  uint64 internal _claimTransferLockTime = 86400 * 2; // 2 days

  // mappings
  mapping(uint64 => Grant) internal _grants;
  mapping(uint64 => uint64) internal _grantClaimLock;
}

contract FundingVault is FundingVaultStorage, IFundingVault, AccessControl {
  bytes32 public constant PLEDGE_MANAGER_ROLE = keccak256("PLEDGE_MANAGER_ROLE");

  event GrantLock(uint64 indexed grantId, uint64 lockTime, uint64 lockTimeout);
  event GrantUpdate(uint64 indexed grantId, uint128 amount, uint64 interval);
  event GrantClaim(uint64 indexed grantId, address indexed to, uint256 amount, uint64 grantTimeUsed);
  
  constructor() {
    _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    _grantRole(PLEDGE_MANAGER_ROLE, _msgSender());

    _vaultTokenAddr = address(new FundingVaultToken(address(this)));
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
    return IFundingVaultToken(_vaultTokenAddr).ownerOf(tokenId);
  }

  function _getTime() internal view returns (uint64) {
    return uint64(block.timestamp);
  }

  function _calculateClaim(uint64 grantId, uint256 requestAmount) internal view returns (uint64, uint64, uint256) {
    Grant memory grant = _grants[grantId];
    
    uint256 claimLimit = grant.claimLimit * 1 ether;
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
    if(_grantClaimLock[grantId] > time) {
      // grant locked
      claimTime = grant.claimTime;
      usedTime = 0;
      claimAmount = 0;
    }
    else if(grant.claimInterval == 0) {
      // no time restriction
      claimTime = time;
      usedTime = 0;
      claimAmount = requestAmount;
    }
    else {
      uint64 baseClaimTime = grant.claimTime;
      uint64 availableTime = time - baseClaimTime;
      if(availableTime > grant.claimInterval) {
        availableTime = grant.claimInterval;
        baseClaimTime = time - grant.claimInterval;
      }

      claimAmount = claimLimit * availableTime / grant.claimInterval;
      if(requestAmount != 0 && requestAmount < claimAmount) {
        // partial claim
        usedTime = uint64(requestAmount * grant.claimInterval / claimLimit);
        if(usedTime * claimLimit / grant.claimInterval < requestAmount) {
          usedTime++; // round up if there is a rounding gap in ETH amount
        }

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

  function getGrants() public view returns (Grant[] memory) {
    IFundingVaultToken vaultToken = IFundingVaultToken(_vaultTokenAddr);
    uint64 grantCount = uint64(vaultToken.totalSupply());
    Grant[] memory grants = new Grant[](grantCount);
    for(uint64 grantIdx = 0; grantIdx < grantCount; grantIdx++) {
      uint64 grantId = uint64(vaultToken.tokenByIndex(grantIdx));
      grants[grantIdx] = _grants[grantId];
    }
    return grants;
  }

  function getGrant(uint64 grantId) public view returns (Grant memory) {
    require(_grants[grantId].claimTime > 0, "grant not found");
    return _grants[grantId];
  }

  function getGrantLockTime(uint32 grantId) public view returns (uint64) {
    require(_grants[grantId].claimTime > 0, "grant not found");
    if(_grantClaimLock[grantId] > uint64(block.timestamp)) {
      return _grantClaimLock[grantId] - uint64(block.timestamp);
    }
    else {
      return 0;
    }
  }

  function getClaimableBalance() public view returns (uint256) {
    uint256 claimableAmount = 0;
    IFundingVaultToken vaultToken = IFundingVaultToken(_vaultTokenAddr);

    uint64 grantCount = uint64(vaultToken.balanceOf(_msgSender()));
    for(uint64 grantIdx = 0; grantIdx < grantCount; grantIdx++) {
      uint64 grantId = uint64(vaultToken.tokenOfOwnerByIndex(_msgSender(), grantIdx));
      claimableAmount += _claimableBalance(grantId);
    }
    return claimableAmount;
  }

  function getClaimableBalance(uint64 grantId) public view returns (uint256) {
    require(_grants[grantId].claimTime > 0, "grant not found");
    return _claimableBalance(grantId);
  }

  function _claimableBalance(uint64 grantId) internal view returns (uint256) {
    (, , uint256 claimAmount) = _calculateClaim(grantId, 0);
    return claimAmount;
  }


  //## Grant managemnet functions (Plege Manager)

  function createGrant(address addr, uint128 amount, uint64 interval) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_vaultTokenAddr != address(0), "not initialized");
    uint64 grantId = _grantIdCounter++;
    IFundingVaultToken(_vaultTokenAddr).tokenUpdate(grantId, addr);

    _grants[grantId] = Grant({
      claimTime: _getTime() - interval,
      claimInterval: interval,
      claimLimit: amount
    });

    emit GrantUpdate(grantId, amount, interval);
  }

  function updateGrant(uint64 grantId, uint128 amount, uint64 interval) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_grants[grantId].claimTime > 0, "grant not found");

    _grants[grantId].claimInterval = interval;
    _grants[grantId].claimLimit = amount;

    emit GrantUpdate(grantId, amount, interval);
  }

  function transferGrant(uint64 grantId, address addr) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_grants[grantId].claimTime > 0, "grant not found");
    IFundingVaultToken(_vaultTokenAddr).tokenUpdate(grantId, addr);
  }

  function removeGrant(uint64 grantId) public onlyRole(PLEDGE_MANAGER_ROLE) {
    require(_grants[grantId].claimTime > 0, "grant not found");

    IFundingVaultToken(_vaultTokenAddr).tokenUpdate(grantId, address(0));
    delete _grants[grantId];
  }

  function lockGrant(uint64 grantId, uint64 lockTime) public {
    require(_grants[grantId].claimTime > 0, "grant not found");
    require(
      _msgSender() == _vaultTokenAddr || 
      _msgSender() == _ownerOf(grantId) || 
      hasRole(PLEDGE_MANAGER_ROLE, _msgSender())
    , "not grant owner or manager");

    _lockGrant(grantId, lockTime);
  }

  function notifyGrantTransfer(uint64 grantId) public {
    require(_grants[grantId].claimTime > 0, "grant not found");
    require(_msgSender() == _vaultTokenAddr, "not grant token contract");

    _lockGrant(grantId, _claimTransferLockTime);
  }

  function _lockGrant(uint64 grantId, uint64 lockTime) internal {
    uint64 lockTimeout = _getTime() + lockTime;
    if(lockTimeout > _grantClaimLock[grantId] || hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
      _grantClaimLock[grantId] = lockTimeout;
    }
    else {
      lockTime = 0;
      lockTimeout = _grantClaimLock[grantId];
    }
    emit GrantLock(grantId, lockTime, lockTimeout);
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

  function claim(uint64 grantId, uint256 amount) public returns (uint256) {
    require(_grants[grantId].claimTime > 0, "grant not found");
    require(_ownerOf(grantId) == _msgSender(), "not owner of this grant");

    uint256 claimAmount = _claim(grantId, amount, _msgSender());
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

  function claimTo(uint64 grantId, uint256 amount, address target) public returns (uint256) {
    require(_grants[grantId].claimTime > 0, "grant not found");
    require(_ownerOf(grantId) == _msgSender(), "not owner of this grant");

    uint256 claimAmount = _claim(grantId, amount, target);
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

    uint64 grantCount = uint64(vaultToken.balanceOf(owner));
    for(uint64 grantIdx = 0; grantIdx < grantCount; grantIdx++) {
      uint64 grantId = uint64(vaultToken.tokenOfOwnerByIndex(owner, grantIdx));
      uint256 claimed = _claim(grantId, amount, target);
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

  function _claim(uint64 grantId, uint256 amount, address target) internal returns (uint256) {
    (uint64 newClaimTime, uint64 usedClaimTime, uint256 claimAmount) = _calculateClaim(grantId, amount);
    if(claimAmount == 0) {
      return 0;
    }

    _grants[grantId].claimTime = newClaimTime;

    // send claim amount to target
    (bool sent, ) = payable(target).call{value: claimAmount}("");
    require(sent, "failed to send ether");

    emit GrantClaim(grantId, target, claimAmount, usedClaimTime);

    return claimAmount;
  }

}
