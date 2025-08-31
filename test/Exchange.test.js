const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("Exchange Contract", function () {
  let Exchange, ABC, exchange, abcToken, owner, user1, user2;

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // 部署ABC代币
    ABC = await ethers.getContractFactory("ABC");
    abcToken = await ABC.deploy(owner.address);

    // 部署Exchange合约
    Exchange = await ethers.getContractFactory("Exchange");
    exchange = await upgrades.deployProxy(Exchange, [abcToken.address, owner.address]);

    // 给用户1一些ABC代币
    await abcToken.mint(user1.address, ethers.parseEther("1000"));
  });

  describe("初始化", function () {
    it("应该正确初始化合约", async function () {
      expect(await exchange.abcToken()).to.equal(abcToken.address);
      expect(await exchange.exchangeRatio()).to.equal(5);
      expect(await exchange.owner()).to.equal(owner.address);
    });
  });

  describe("管理员功能", function () {
    it("管理员可以设置兑换比例", async function () {
      await exchange.setExchangeRatio(10);
      expect(await exchange.exchangeRatio()).to.equal(10);
    });

    it("非管理员不能设置兑换比例", async function () {
      await expect(
        exchange.connect(user1).setExchangeRatio(10)
      ).to.be.revertedWithCustomError(exchange, "OwnableUnauthorizedAccount");
    });

    it("管理员可以存入ABC代币", async function () {
      const amount = ethers.parseEther("100");
      await abcToken.approve(exchange.address, amount);
      await exchange.depositAbc(amount);
      expect(await exchange.abcBalance()).to.equal(amount);
    });

    it("管理员可以存入CFX", async function () {
      const amount = ethers.parseEther("10");
      await exchange.depositCfx({ value: amount });
      expect(await ethers.provider.getBalance(exchange.address)).to.equal(amount);
    });
  });

  describe("兑换功能", function () {
    beforeEach(async function () {
      // 管理员存入一些ABC和CFX
      const abcAmount = ethers.parseEther("1000");
      const cfxAmount = ethers.parseEther("100");
      
      await abcToken.approve(exchange.address, abcAmount);
      await exchange.depositAbc(abcAmount);
      await exchange.depositCfx({ value: cfxAmount });
    });

    it("用户可以用ABC兑换CFX", async function () {
      const abcAmount = ethers.parseEther("50");
      const expectedCfxAmount = abcAmount / 5n; // 5:1比例

      await abcToken.connect(user1).approve(exchange.address, abcAmount);
      
      const initialCfxBalance = await ethers.provider.getBalance(user1.address);
      await exchange.connect(user1).exchangeAbcToCfx(abcAmount);
      const finalCfxBalance = await ethers.provider.getBalance(user1.address);

      expect(finalCfxBalance - initialCfxBalance).to.equal(expectedCfxAmount);
    });

    it("用户可以用CFX兑换ABC", async function () {
      const cfxAmount = ethers.parseEther("10");
      const expectedAbcAmount = cfxAmount * 5n; // 5:1比例

      const initialAbcBalance = await abcToken.balanceOf(user1.address);
      await exchange.connect(user1).exchangeCfxToAbc({ value: cfxAmount });
      const finalAbcBalance = await abcToken.balanceOf(user1.address);

      expect(finalAbcBalance - initialAbcBalance).to.equal(expectedAbcAmount);
    });
  });

  describe("待兑换订单", function () {
    it("当余额不足时创建待兑换订单", async function () {
      const abcAmount = ethers.parseEther("1000");
      await abcToken.connect(user1).approve(exchange.address, abcAmount);
      
      await exchange.connect(user1).exchangeAbcToCfx(abcAmount);
      
      const order = await exchange.getPendingOrder(1);
      expect(order.user).to.equal(user1.address);
      expect(order.amount).to.equal(abcAmount);
      expect(order.isAbcToCfx).to.be.true;
      expect(order.executed).to.be.false;
    });

    it("管理员可以执行待兑换订单", async function () {
      const abcAmount = ethers.parseEther("1000");
      await abcToken.connect(user1).approve(exchange.address, abcAmount);
      
      await exchange.connect(user1).exchangeAbcToCfx(abcAmount);
      
      // 管理员存入CFX
      const cfxAmount = ethers.parseEther("200");
      await exchange.depositCfx({ value: cfxAmount });
      
      // 执行订单
      await exchange.executePendingOrder(1);
      
      const order = await exchange.getPendingOrder(1);
      expect(order.executed).to.be.true;
    });
  });
}); 