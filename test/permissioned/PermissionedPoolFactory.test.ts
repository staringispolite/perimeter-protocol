import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { deployMockERC20 } from "../support/erc20";
import {
  DEFAULT_POOL_SETTINGS,
  deployPoolControllerFactory,
  deployWithdrawControllerFactory
} from "../support/pool";
import { deployToSAcceptanceRegistry } from "../support/tosacceptanceregistry";

describe("PermissionedPoolFactory", () => {
  async function deployFixture() {
    // Contracts are deployed using the first signer/account by default
    const [operator, otherAccount] = await ethers.getSigners();

    // Deploy the liquidity asset
    const { mockERC20: liquidityAsset } = await deployMockERC20();

    // Deploy the Service Configuration contract
    const PermissionedServiceConfiguration = await ethers.getContractFactory(
      "PermissionedServiceConfiguration",
      operator
    );
    const permissionedServiceConfiguration =
      await PermissionedServiceConfiguration.deploy();
    await permissionedServiceConfiguration.deployed();

    // Deploy ToS Registry
    const { tosAcceptanceRegistry } = await deployToSAcceptanceRegistry(
      permissionedServiceConfiguration
    );

    // Configure ToS
    await permissionedServiceConfiguration
      .connect(operator)
      .setToSAcceptanceRegistry(tosAcceptanceRegistry.address);
    await tosAcceptanceRegistry
      .connect(operator)
      .updateTermsOfService("https://terms.example");

    // Deploy the PoolAdminAccessControl contract
    const PoolAdminAccessControl = await ethers.getContractFactory(
      "PoolAdminAccessControl"
    );
    const poolAdminAccessControl = await PoolAdminAccessControl.deploy(
      permissionedServiceConfiguration.address
    );
    await poolAdminAccessControl.deployed();

    // Deploy library for linking
    const PoolLib = await ethers.getContractFactory("PoolLib");
    const poolLib = await PoolLib.deploy();

    // Deploy PoolAccessControlFactory as a dependency to the PoolFactory
    const PoolAccessControlFactory = await ethers.getContractFactory(
      "PoolAccessControlFactory"
    );
    const poolAccessControlFactory = await PoolAccessControlFactory.deploy(
      permissionedServiceConfiguration.address
    );

    // Deploy the PermissionedPoolFactory
    const PoolFactory = await ethers.getContractFactory(
      "PermissionedPoolFactory",
      {
        libraries: {
          PoolLib: poolLib.address
        }
      }
    );
    const poolFactory = await PoolFactory.deploy(
      permissionedServiceConfiguration.address,
      poolAccessControlFactory.address
    );
    await poolFactory.deployed();

    // Initialize ServiceConfiguration
    const tx = await permissionedServiceConfiguration.setPoolAdminAccessControl(
      poolAdminAccessControl.address
    );
    await tx.wait();

    const withdrawControllerFactory = await deployWithdrawControllerFactory(
      poolLib.address,
      permissionedServiceConfiguration.address
    );

    const poolControllerFactory = await deployPoolControllerFactory(
      poolLib.address,
      permissionedServiceConfiguration.address
    );

    return {
      poolFactory,
      poolAdminAccessControl,
      operator,
      otherAccount,
      liquidityAsset,
      tosAcceptanceRegistry,
      withdrawControllerFactory,
      poolControllerFactory
    };
  }

  it("emits PoolCreated", async () => {
    const {
      poolFactory,
      poolAdminAccessControl,
      otherAccount,
      liquidityAsset,
      tosAcceptanceRegistry,
      withdrawControllerFactory,
      poolControllerFactory
    } = await loadFixture(deployFixture);

    await tosAcceptanceRegistry.connect(otherAccount).acceptTermsOfService();
    await poolAdminAccessControl.allow(otherAccount.getAddress());

    await expect(
      poolFactory
        .connect(otherAccount)
        .createPool(
          liquidityAsset.address,
          withdrawControllerFactory.address,
          poolControllerFactory.address,
          DEFAULT_POOL_SETTINGS
        )
    ).to.emit(poolFactory, "PoolCreated");
  });

  it("reverts if not called by a Pool Admin", async () => {
    const {
      poolFactory,
      poolAdminAccessControl,
      otherAccount,
      liquidityAsset,
      tosAcceptanceRegistry,
      withdrawControllerFactory,
      poolControllerFactory
    } = await loadFixture(deployFixture);

    await tosAcceptanceRegistry.connect(otherAccount).acceptTermsOfService();
    await poolAdminAccessControl.allow(otherAccount.getAddress());

    await expect(
      poolFactory.createPool(
        liquidityAsset.address,
        withdrawControllerFactory.address,
        poolControllerFactory.address,
        DEFAULT_POOL_SETTINGS
      )
    ).to.be.revertedWith("caller is not allowed pool admin");
  });

  it("access control reverts if PM hasn't accepted ToS", async () => {
    const { poolAdminAccessControl, otherAccount } = await loadFixture(
      deployFixture
    );

    await expect(
      poolAdminAccessControl.allow(otherAccount.getAddress())
    ).to.be.revertedWith("Pool: no ToS acceptance recorded");
  });
});
