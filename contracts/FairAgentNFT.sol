// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC8004Registry} from "../interfaces/IERC8004Registry.sol";

/// FairAgent NFT. 1 NFT per mint, bonding-curve price, 10% instant referral,
/// internal marketplace with 5% fee, ERC-2981 royalty for outside marketplaces.
/// Owner can withdraw the full balance (mint revenue + market fees) to `treasury`.
contract FairAgentNFT is ERC721, Ownable2Step, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 6_000; // 5,000 paid + 1,000 free claims
    uint256 public constant START_PRICE = 0.02 ether;
    uint256 public constant PRICE_STEP = 0.0001 ether;
    uint256 public constant MAX_PER_TX = 20;
    uint256 public constant REFERRAL_BPS = 1_000; // 10% of mint price
    uint256 public constant MARKET_FEE_BPS = 500; // 5%
    uint256 public constant ROYALTY_BPS = 500; // 5% ERC-2981
    uint256 public constant CLAIM_SUPPLY = 1_000; // free NFTs (claimer pays only claimFee)
    uint256 public constant MAX_CLAIM_FEE = 0.01 ether; // hard cap on the owner-adjustable fee

    address payable public treasury;
    uint256 public totalMinted;
    bool public mintOpen;
    bool public claimOpen;
    uint256 public claimed; // free claims so far
    uint256 public claimFee = 0.0008 ether; // flat fee per claim, goes to owner via withdraw()
    mapping(address => bool) public hasClaimed;
    string public baseURI;
    string public contractURI; // ERC-7572 collection metadata (name, logo, description) for marketplaces
    bool public metadataFrozen; // one-way: once true, baseURI can never change

    // Scheduled launch, set by the owner from the admin page and enforced here, not in the browser.
    // 0 = no schedule (the bool switch alone decides). Once the moment has passed it cannot be pushed later.
    uint256 public mintStartAt;
    uint256 public mintEndAt;
    uint256 public claimStartAt;
    uint256 public claimEndAt;
    uint256 public constant MAX_SCHEDULE_AHEAD = 365 days;

    mapping(address => uint256) public referralCount; // NFTs minted via this inviter
    mapping(address => uint256) public referralEarned; // BNB paid to inviter
    // Bridge readiness (omnichain / lock-free path). Ids are a closed set 1..6000, so a bridge can only
    // re-mint an id that was first burned here: it can never inflate supply beyond MAX_SUPPLY.
    mapping(uint256 => bool) public burned;
    uint256 public burnedCount;
    address public bridge;
    address public pendingBridge;
    uint256 public bridgeReadyAt;
    uint256 public constant BRIDGE_DELAY = 3 days;
    mapping(uint256 => uint256) public listingPrice; // tokenId => price, 0 = not listed

    // ERC-8004 identity registry (immutable: no owner power over it after deploy).
    // Zero address = feature off. Every registration is opt-in per token, so a broken or
    // paused registry can never block mint / claim / staking / trading.
    address public immutable agentRegistry;
    mapping(uint256 => bool) public agentRegistered; // FairAgent tokenId => registered on ERC-8004
    mapping(uint256 => uint256) public agentIdOf;    // FairAgent tokenId => ERC-8004 agentId
    uint256 public registeredAgents;

    event Minted(address indexed buyer, uint256 firstId, uint256 qty, uint256 paid, address indexed ref, uint256 commission);
    event Claimed(address indexed to, uint256 id, uint256 fee);
    event ClaimFeeSet(uint256 fee);
    event MintOpenSet(bool open);
    event ClaimOpenSet(bool open);
    event TreasurySet(address indexed treasury);
    event Listed(uint256 indexed id, address indexed seller, uint256 price);
    event Unlisted(uint256 indexed id);
    event Sold(uint256 indexed id, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event Withdrawn(address indexed to, uint256 amount);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId); // ERC-4906: marketplaces refresh
    event MetadataFrozen(string baseURI);
    event ContractURIUpdated(); // ERC-7572

    error MintClosed(); error BadQty(); error SoldOut(); error Underpaid();
    error ZeroAddress(); error NotTokenOwner(); error NotListed(); error BadPrice(); error NotApproved(); error SendFailed(); error MetadataIsFrozen(); error EmptyURI();
    event Burned(uint256 indexed id, address indexed by);
    event BridgeProposed(address indexed bridge, uint256 readyAt);
    event BridgeSet(address indexed bridge);
    error NotBridge(); error NotBurned(); error BridgeNotReady();
    error ClaimClosed(); error AlreadyClaimed(); error ClaimsExhausted(); error FeeTooHigh();
    error NothingToWithdraw();
    event MintStartScheduled(uint256 startAt);
    event ClaimStartScheduled(uint256 startAt);
    event MintEndScheduled(uint256 endAt);
    event ClaimEndScheduled(uint256 endAt);
    error BadLaunchTime(); error LaunchAlreadyStarted(); error NoSchedule();
    error BadEndTime(); error SaleEnded();
    event AgentRegistered(uint256 indexed id, uint256 indexed agentId, address indexed owner, string agentURI);
    error RegistryNotConfigured(); error AlreadyRegistered(); error BadAgentURI(); error RegistryFailed();

    constructor(address initialOwner, address payable treasury_, string memory baseURI_, address agentRegistry_)
        ERC721("FairAgent", "FAGENT") Ownable(initialOwner)
    {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        baseURI = baseURI_;
        agentRegistry = agentRegistry_;
    }

    // ------------------------------------------------------------ mint

    function priceAt(uint256 minted) public pure returns (uint256) { return START_PRICE + PRICE_STEP * minted; }

    /// True only when the switch is on AND the owner-set launch moment has passed. The website reads
    /// this for the countdown, but the check below is what actually decides.
    function mintLive() public view returns (bool) {
        return mintOpen && (mintStartAt == 0 || block.timestamp >= mintStartAt) && (mintEndAt == 0 || block.timestamp < mintEndAt);
    }
    function claimLive() public view returns (bool) {
        return claimOpen && (claimStartAt == 0 || block.timestamp >= claimStartAt) && (claimEndAt == 0 || block.timestamp < claimEndAt);
    }

    function quote(uint256 qty) public view returns (uint256 total) {
        uint256 m = totalMinted - claimed; // free claims do not move the price curve
        // sum of arithmetic series
        total = qty * START_PRICE + PRICE_STEP * (qty * m + qty * (qty - 1) / 2);
    }

    function mint(uint256 qty, address ref) external payable nonReentrant {
        if (!mintLive()) revert MintClosed();
        if (qty == 0 || qty > MAX_PER_TX) revert BadQty();
        // capacity still reserved for free claims is not sellable
        if (totalMinted + qty + (CLAIM_SUPPLY - claimed) > MAX_SUPPLY) revert SoldOut();
        uint256 cost = quote(qty);
        if (msg.value < cost) revert Underpaid();

        uint256 first = totalMinted + 1;
        totalMinted += qty;
        for (uint256 i; i < qty;) {
            _mint(msg.sender, first + i);
            unchecked { ++i; } // qty <= MAX_PER_TX, cannot overflow
        }

        uint256 commission = 0;
        if (ref != address(0) && ref != msg.sender && balanceOf(ref) > 0) {
            uint256 c = cost * REFERRAL_BPS / 10_000;
            // Gas-capped push payment: an inviter contract cannot run logic here. If it cannot
            // receive, the commission stays in the contract (owner revenue) and the mint still succeeds.
            bool ok;
            assembly { ok := call(30000, ref, c, 0, 0, 0, 0) } // no returndata copy (return-bomb safe)
            if (ok) {
                commission = c;
                referralCount[ref] += qty;
                referralEarned[ref] += c;
            }
        }
        if (msg.value > cost) _send(msg.sender, msg.value - cost);
        emit Minted(msg.sender, first, qty, cost, ref, commission);
    }

    /// Free NFT, 1 per wallet, up to CLAIM_SUPPLY. Caller pays only `claimFee` (+ gas).
    function claim() external payable nonReentrant {
        if (!claimLive()) revert ClaimClosed();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();
        if (claimed >= CLAIM_SUPPLY) revert ClaimsExhausted();
        uint256 fee = claimFee;
        if (msg.value < fee) revert Underpaid();
        hasClaimed[msg.sender] = true;
        claimed += 1;
        uint256 id = ++totalMinted;
        _mint(msg.sender, id);
        if (msg.value > fee) _send(msg.sender, msg.value - fee);
        emit Claimed(msg.sender, id, fee);
    }

    // ------------------------------------------------------------ internal marketplace

    function list(uint256 id, uint256 price) external {
        if (ownerOf(id) != msg.sender) revert NotTokenOwner();
        if (price == 0) revert BadPrice();
        listingPrice[id] = price;
        emit Listed(id, msg.sender, price);
    }

    function unlist(uint256 id) external {
        if (ownerOf(id) != msg.sender) revert NotTokenOwner();
        delete listingPrice[id];
        emit Unlisted(id);
    }

    /// Seller must have approved this contract (approve or setApprovalForAll).
    function buy(uint256 id) external payable nonReentrant {
        uint256 price = listingPrice[id];
        if (price == 0) revert NotListed();
        if (msg.value < price) revert Underpaid();
        address seller = ownerOf(id);
        if (getApproved(id) != address(this) && !isApprovedForAll(seller, address(this))) revert NotApproved();

        delete listingPrice[id];
        uint256 fee = price * MARKET_FEE_BPS / 10_000;
        _transfer(seller, msg.sender, id);
        _send(seller, price - fee);
        if (msg.value > price) _send(msg.sender, msg.value - price);
        emit Sold(id, seller, msg.sender, price, fee);
    }

    /// Any transfer (also on outside marketplaces) clears a stale listing.
    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (listingPrice[id] != 0) { delete listingPrice[id]; emit Unlisted(id); }
        return super._update(to, id, auth);
    }

    // ------------------------------------------------------------ owner

    function setMintOpen(bool v) external onlyOwner { mintOpen = v; emit MintOpenSet(v); }
    function setClaimOpen(bool v) external onlyOwner { claimOpen = v; emit ClaimOpenSet(v); }

    /// Arm the paid sale and open it automatically at `startAt` (unix seconds, WIB is just how the
    /// admin page shows it). The countdown on the site is backed by this timestamp, so a finished
    /// countdown really does open the door. Moving the date is only possible before it fires.
    function scheduleMint(uint256 startAt) external onlyOwner { _scheduleMint(startAt); }

    function _scheduleMint(uint256 startAt) internal {
        if (startAt <= block.timestamp || startAt > block.timestamp + MAX_SCHEDULE_AHEAD) revert BadLaunchTime();
        if (mintStartAt != 0 && block.timestamp >= mintStartAt) revert LaunchAlreadyStarted();
        mintStartAt = startAt;
        mintOpen = true;
        emit MintOpenSet(true);
        emit MintStartScheduled(startAt);
    }

    function scheduleClaim(uint256 startAt) external onlyOwner { _scheduleClaim(startAt); }

    function _scheduleClaim(uint256 startAt) internal {
        if (startAt <= block.timestamp || startAt > block.timestamp + MAX_SCHEDULE_AHEAD) revert BadLaunchTime();
        if (claimStartAt != 0 && block.timestamp >= claimStartAt) revert LaunchAlreadyStarted();
        claimStartAt = startAt;
        claimOpen = true;
        emit ClaimOpenSet(true);
        emit ClaimStartScheduled(startAt);
    }

    /// Cancel a launch that has not fired yet: clears the date and closes the door again.
    function cancelMintSchedule() external onlyOwner {
        if (mintStartAt == 0) revert NoSchedule();
        if (block.timestamp >= mintStartAt) revert LaunchAlreadyStarted();
        mintStartAt = 0;
        mintEndAt = 0;
        mintOpen = false;
        emit MintOpenSet(false);
        emit MintStartScheduled(0);
        emit MintEndScheduled(0);
    }

    function cancelClaimSchedule() external onlyOwner {
        if (claimStartAt == 0) revert NoSchedule();
        if (block.timestamp >= claimStartAt) revert LaunchAlreadyStarted();
        claimStartAt = 0;
        claimEndAt = 0;
        claimOpen = false;
        emit ClaimOpenSet(false);
        emit ClaimStartScheduled(0);
        emit ClaimEndScheduled(0);
    }

    /// Close time for the paid sale. The countdown on the site reads this, and mintLive() enforces it,
    /// so a finished countdown really does shut the door. A sale that already ended cannot be revived.
    function setMintEnd(uint256 endAt) external onlyOwner { _setMintEnd(endAt); }

    function setClaimEnd(uint256 endAt) external onlyOwner {
        if (endAt <= block.timestamp || endAt > block.timestamp + MAX_SCHEDULE_AHEAD) revert BadEndTime();
        if (claimEndAt != 0 && block.timestamp >= claimEndAt) revert SaleEnded();
        if (claimStartAt != 0 && endAt <= claimStartAt) revert BadEndTime();
        claimEndAt = endAt;
        emit ClaimEndScheduled(endAt);
    }

    /// One call for the admin page: open at `startAt`, close at `endAt`.
    function scheduleMintWindow(uint256 startAt, uint256 endAt) external onlyOwner {
        if (endAt <= startAt) revert BadEndTime();
        _scheduleMint(startAt);
        _setMintEnd(endAt);
    }

    function scheduleClaimWindow(uint256 startAt, uint256 endAt) external onlyOwner {
        if (endAt <= startAt) revert BadEndTime();
        _scheduleClaim(startAt);
        if (endAt <= block.timestamp || endAt > block.timestamp + MAX_SCHEDULE_AHEAD) revert BadEndTime();
        claimEndAt = endAt;
        emit ClaimEndScheduled(endAt);
    }

    function _setMintEnd(uint256 endAt) internal {
        if (endAt <= block.timestamp || endAt > block.timestamp + MAX_SCHEDULE_AHEAD) revert BadEndTime();
        if (mintEndAt != 0 && block.timestamp >= mintEndAt) revert SaleEnded();
        if (mintStartAt != 0 && endAt <= mintStartAt) revert BadEndTime();
        mintEndAt = endAt;
        emit MintEndScheduled(endAt);
    }
    function setClaimFee(uint256 f) external onlyOwner {
        if (f > MAX_CLAIM_FEE) revert FeeTooHigh();
        claimFee = f;
        emit ClaimFeeSet(f);
    }
    /// Reveal / metadata move. Blocked forever after freezeMetadata().
    function setBaseURI(string calldata u) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        if (bytes(u).length == 0) revert EmptyURI();
        baseURI = u;
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
    }

    /// One-shot, irreversible: locks baseURI so art and traits can never be changed by the owner.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        if (bytes(baseURI).length == 0) revert EmptyURI();
        metadataFrozen = true;
        emit MetadataFrozen(baseURI);
    }
    /// ERC-7572 collection-level metadata. Does not affect token art or traits.
    function setContractURI(string calldata u) external onlyOwner {
        contractURI = u;
        emit ContractURIUpdated();
    }
    function setTreasury(address payable t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    /// Full balance (mint revenue + market fees) to treasury.
    function withdraw() external onlyOwner nonReentrant {
        uint256 amt = address(this).balance;
        if (amt == 0) revert NothingToWithdraw();
        _send(treasury, amt);
        emit Withdrawn(treasury, amt);
    }

    // ------------------------------------------------------------ misc

    // ------------------------------------------------------------ ERC-8004 identity (opt-in, per token)

    /// Register this token as an ERC-8004 agent on the registry fixed at deploy time.
    /// Caller must own the token. The registry mints the agent identity to this contract
    /// (msg.sender of register()), so the identity is forwarded to the holder in the same tx.
    /// Anyone can verify the link on-chain via agentIdOf(id) / agentRegistered(id), and the
    /// agent shows up in 8004scan / Agent0 under the URI passed here.
    /// Registration costs gas only: the BNB Chain registry charges no protocol fee.
    function registerAgent(uint256 id, string calldata agentURI) external nonReentrant {
        address reg = agentRegistry;
        if (reg == address(0)) revert RegistryNotConfigured();
        if (_ownerOf(id) != msg.sender) revert NotTokenOwner();
        if (agentRegistered[id]) revert AlreadyRegistered();
        if (!_validAgentURI(agentURI)) revert BadAgentURI();

        uint256 agentId;
        try IERC8004Registry(reg).register(agentURI) returns (uint256 a) {
            agentId = a;
        } catch {
            revert RegistryFailed();
        }
        // The identity NFT is minted to this contract; hand it to the holder so the agent
        // is theirs (the registry clears agentWallet on transfer, they can set it later).
        try IERC721(reg).transferFrom(address(this), msg.sender, agentId) {} catch { revert RegistryFailed(); }

        agentRegistered[id] = true;
        agentIdOf[id] = agentId;
        registeredAgents += 1;
        emit AgentRegistered(id, agentId, msg.sender, agentURI);
    }

    /// Only the ERC-8004 registry may safely mint into this contract, and nothing else.
    /// Any other safeTransferFrom of a foreign NFT reverts, so tokens cannot get stuck here.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        return msg.sender == agentRegistry ? IERC721Receiver.onERC721Received.selector : bytes4(0xffffffff);
    }

    /// Cheap scheme allowlist: ipfs:// , https:// , ar:// (no javascript:/data: URIs).
    function _validAgentURI(string calldata u) private pure returns (bool) {
        bytes calldata b = bytes(u);
        uint256 n = b.length;
        if (n < 6 || n > 512) return false;
        if (n >= 7 && b[0] == "i" && b[1] == "p" && b[2] == "f" && b[3] == "s" && b[4] == ":" && b[5] == "/" && b[6] == "/") return true;
        if (n >= 8 && b[0] == "h" && b[1] == "t" && b[2] == "t" && b[3] == "p" && b[4] == "s" && b[5] == ":" && b[6] == "/" && b[7] == "/") return true;
        if (n >= 6 && b[0] == "a" && b[1] == "r" && b[2] == ":" && b[3] == "/" && b[4] == "/") return true;
        return false;
    }

    // ------------------------------------------------------------ bridge readiness

    /// Holder (or approved operator) burns a token, e.g. to move it to another chain through a bridge.
    function burn(uint256 id) external {
        _update(address(0), id, _msgSender()); // reverts unless owner/approved; clears any listing
        burned[id] = true; burnedCount++;
        emit Burned(id, msg.sender);
    }

    /// Owner proposes a bridge contract. It becomes usable only after BRIDGE_DELAY (public notice).
    function proposeBridge(address b) external onlyOwner {
        if (b == address(0)) revert ZeroAddress();
        pendingBridge = b; bridgeReadyAt = block.timestamp + BRIDGE_DELAY;
        emit BridgeProposed(b, bridgeReadyAt);
    }

    function activateBridge() external onlyOwner {
        if (pendingBridge == address(0) || block.timestamp < bridgeReadyAt) revert BridgeNotReady();
        bridge = pendingBridge; delete pendingBridge; delete bridgeReadyAt;
        emit BridgeSet(bridge);
    }

    /// Owner can cancel a pending bridge or switch the active one off at any time (only reduces power).
    function revokeBridge() external onlyOwner {
        delete bridge; delete pendingBridge; delete bridgeReadyAt;
        emit BridgeSet(address(0));
    }

    /// Bridge restores an id that was burned here (token arrived back from another chain).
    function bridgeMint(address to, uint256 id) external {
        if (msg.sender != bridge || bridge == address(0)) revert NotBridge();
        if (!burned[id]) revert NotBurned();
        delete burned[id]; burnedCount--;
        _mint(to, id);
    }

    // ------------------------------------------------------------ read-only helpers for future modules
    // View-only. Staking, ERC-6551 accounts, ERC-8004 registries, MCP/AI servers and dapps read these
    // instead of needing new NFT code. Supply = minted - burned.

    function totalSupply() external view returns (uint256) { return totalMinted - burnedCount; }

    /// Rarity tier by token id: 3 = Genesis (1-250), 2 = Pro (251-1500), 1 = Core (1501+).
    function tierOf(uint256 id) external view returns (uint256) {
        _requireOwned(id);
        return id <= 250 ? 3 : id <= 1500 ? 2 : 1;
    }

    /// All token ids held by `a`. Meant for off-chain reads (loops over minted ids).
    function tokensOfOwner(address a) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(a);
        ids = new uint256[](n);
        uint256 k;
        for (uint256 i = 1; i <= totalMinted && k < n; i++) if (_ownerOf(i) == a) ids[k++] = i;
    }

    function _baseURI() internal view override returns (string memory) { return baseURI; }

    /// ERC-2981: 5% of any sale price to treasury. Outside marketplaces may ignore it.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (treasury, salePrice * ROYALTY_BPS / 10_000);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0x2a55205a || id == 0x49064906 || super.supportsInterface(id);
    }

    function _send(address to, uint256 amt) internal {
        bool ok;
        assembly { ok := call(gas(), to, amt, 0, 0, 0, 0) } // no returndata copy (return-bomb safe)
        if (!ok) revert SendFailed();
    }
}
