// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DuelTestBase} from "../utils/DuelTestBase.sol";
import {DuelDeploy, TreasuryProbe} from "../../script/DuelDeploy.sol";
import {DuelRouter} from "../../src/DuelRouter.sol";
import {DuelToken} from "../../src/DuelToken.sol";

/// @dev A read-only compatibility fixture: the old identifying interface alone does not attest permit support.
contract VersionLabelOnlyRouter {
    IPoolManager public immutable poolManager;
    uint256 public constant VERSION = 1;
    string public constant CODENAME = "Petunia";

    constructor(IPoolManager manager_) {
        poolManager = manager_;
    }
}

contract RuntimeChecks {
    function check(address at, string calldata artifact, bytes calldata args) external returns (bool) {
        return DuelDeploy.sameCode(at, artifact, args);
    }

    function deployment(
        DuelDeploy.Deployment memory d,
        IPoolManager manager,
        address owner,
        address treasury,
        TreasuryProbe probe
    ) external {
        DuelDeploy.checkDeployment(d, manager, owner, treasury, probe);
    }
}

contract DuelDeploymentSecurityTest is DuelTestBase {
    // Foundry encodes JSON object fields in alphabetical order.
    struct ImmutableReference {
        uint256 length;
        uint256 start;
    }

    RuntimeChecks internal checks;
    TreasuryProbe internal probe;

    /// @dev The deployment as it is born: its launches still paused.
    function _opened() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        checks = new RuntimeChecks();
        probe = new TreasuryProbe();
        vm.deal(address(probe), 1 ether);
    }

    function _deployment() internal view returns (DuelDeploy.Deployment memory) {
        return DuelDeploy.Deployment(hook, factory, router, lens);
    }

    function test_localRuntimeAndLinksAttestTheCurrentDeployment() public {
        checks.deployment(_deployment(), manager, owner, treasury, probe);
        // its owner opens the launches: the tokens of a pair anyone launches
        vm.prank(owner);
        factory.setPaused(false);
        PairInfo memory pair = _createPair(0, 0, false);
        for (uint256 i = 0; i < 2; ++i) {
            address token = i == 0 ? address(pair.a) : address(pair.d);
            (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying,,) =
                (i == 0 ? pair.a : pair.d).eip712Domain();
            assertEq(uint8(fields), 15);
            assertEq(name, "Duel");
            assertEq(version, "1");
            assertEq(chainId, block.chainid);
            assertEq(verifying, token);
            _assertDomain(DuelToken(token), chainId);
        }
    }

    function test_versionAndPoolManagerLabelsDoNotAttestPermitRuntime() public {
        VersionLabelOnlyRouter labels = new VersionLabelOnlyRouter(manager);
        assertEq(labels.VERSION(), router.VERSION());
        assertEq(labels.CODENAME(), router.CODENAME());
        assertEq(address(labels.poolManager()), address(manager));
        DuelDeploy.Deployment memory d = _deployment();
        d.router = DuelRouter(address(labels));
        vm.expectRevert("DuelDeploy: router code");
        checks.deployment(d, manager, owner, treasury, probe);
    }

    function test_aSameLengthDifferentRuntimeIsRejected() public {
        bytes memory changed = address(router).code;
        changed[0] = bytes1(uint8(changed[0]) ^ 1);
        address candidate = makeAddr("different compiled runtime");
        vm.etch(candidate, changed);
        assertEq(candidate.code.length, address(router).code.length);
        assertFalse(checks.check(candidate, "DuelRouter.sol:DuelRouter", abi.encode(manager)));
    }

    function test_runtimeAttestationIncludesImmutableDependencyAndLinkChecks() public {
        IPoolManager otherManager = IPoolManager(makeAddr("different manager"));
        DuelRouter elsewhere = new DuelRouter(otherManager);
        assertTrue(checks.check(address(elsewhere), "DuelRouter.sol:DuelRouter", abi.encode(otherManager)));
        assertFalse(checks.check(address(elsewhere), "DuelRouter.sol:DuelRouter", abi.encode(manager)));
        DuelDeploy.Deployment memory d = _deployment();
        d.router = elsewhere;
        vm.expectRevert("DuelDeploy: not on the PoolManager");
        checks.deployment(d, manager, owner, treasury, probe);
    }

    function test_runtimeAttestationRejectsInconsistentOccurrencesOfAnImmutable() public {
        bytes memory changed = address(router).code;
        bytes memory expected = vm.getDeployedCode("DuelRouter.sol:DuelRouter");
        string memory json = vm.readFile(vm.getArtifactPathByDeployedCode(expected));
        string[] memory ids = vm.parseJsonKeys(json, ".deployedBytecode.immutableReferences");
        assertEq(ids.length, 1, "router has exactly one immutable dependency");
        ImmutableReference[] memory refs = abi.decode(
            vm.parseJson(json, string.concat(".deployedBytecode.immutableReferences['", ids[0], "']")),
            (ImmutableReference[])
        );
        assertGt(refs.length, 1, "the check must exercise repeated references");
        assertEq(refs[1].length, 32);
        changed[refs[1].start + 31] = bytes1(uint8(changed[refs[1].start + 31]) ^ 1);
        address candidate = makeAddr("inconsistent compiled constants");
        vm.etch(candidate, changed);
        // Inspect this fixture's code only; no modified runtime is executed.
        assertFalse(checks.check(candidate, "DuelRouter.sol:DuelRouter", abi.encode(manager)));
    }

    function test_domainHashMatchesIndependentEncodingAndTracksTheChain() public {
        vm.chainId(31_337);
        vm.prank(owner);
        factory.setPaused(false);
        PairInfo memory pair = _createPair(0, 0, false);
        _assertDomain(pair.a, 31_337);
        _assertDomain(pair.d, 31_337);
        assertNotEq(pair.a.DOMAIN_SEPARATOR(), pair.d.DOMAIN_SEPARATOR());
        vm.chainId(31_338);
        _assertDomain(pair.a, 31_338);
        _assertDomain(pair.d, 31_338);
        vm.chainId(31_337);
        _assertDomain(pair.a, 31_337);
    }

    function _assertDomain(DuelToken token, uint256 chainId) internal view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Duel"),
                keccak256("1"),
                chainId,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }
}
