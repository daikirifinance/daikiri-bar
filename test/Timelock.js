const { assert, expect } = require('chai')
const { ethers } = require('hardhat')
const { expectRevert, time } = require('@openzeppelin/test-helpers')

let deployer, alice, bob
let daiki, timelock, bartender, exampleToken

function encodeParameters(types, values) {
    const abi = new ethers.utils.AbiCoder();
    return abi.encode(types, values);
}

describe('Timelock', async () => {

    beforeEach(async () => {
        [deployer, alice, bob] = await ethers.getSigners();
        const DaikiToken = await ethers.getContractFactory('DaikiToken');
        daiki = await DaikiToken.connect(deployer).deploy();

        const Timelock = await ethers.getContractFactory('Timelock');
        timelock = await Timelock.connect(deployer).deploy(deployer.address, 60 * 60 * 12);       

        const Bartender = await ethers.getContractFactory('Bartender')
        bartender = await Bartender.connect(deployer).deploy(daiki.address, '1000', deployer.address, '1000000000000000000')

        const ERC20 = await ethers.getContractFactory('ERC20')
        exampleToken = await ERC20.connect(deployer).deploy("Example Token", "EXAMPLE")
    })

    it('should revert if not owner', async () => {       
        await daiki.connect(deployer).transferOwnership(timelock.address);

        await expect(
            daiki.connect(alice).transferOwnership(bob.address)
        ).to.be.revertedWith('Ownable: caller is not the owner');

        await expect(
            timelock.connect(bob).queueTransaction(
                daiki.address, '0', 'transferOwnership(address)',
                encodeParameters(['address'], [alice.address]),
                (await time.latest()).add(time.duration.hours(6)).toString(),
            )
        ).to.be.revertedWith('Timelock::queueTransaction: Call must come from admin.');
    })

    it('should timelock tx to change ownership', async () => {
        await daiki.connect(deployer).transferOwnership(timelock.address);

        const eta =(await time.latest()).add(time.duration.hours(13));
        await timelock.connect(deployer).queueTransaction(
            daiki.address, '0', 'transferOwnership(address)',
            encodeParameters(['address'], [alice.address]), eta.toString()
        )
        
        await time.increase(time.duration.hours(1))

        await expect(
            timelock.connect(deployer).executeTransaction(
                daiki.address, '0', 'transferOwnership(address)',
                encodeParameters(['address'], [alice.address]), eta.toString()
            )
        ).to.be.revertedWith("Timelock::executeTransaction: Transaction hasn't surpassed time lock.")
                
        await time.increase(time.duration.hours(12))

        await timelock.connect(deployer).executeTransaction(
            daiki.address, '0', 'transferOwnership(address)',
            encodeParameters(['address'], [alice.address]), eta.toString()
        )

        const owner = await daiki.owner()
        assert.equal(owner, alice.address, 'Incorrect owner')
    })

    it('should timelock Bartender', async () => {
        await daiki.connect(deployer).transferOwnership(bartender.address)
        await bartender.connect(deployer).transferOwnership(timelock.address)

        let daiki_owner = await daiki.owner()
        let bartender_owner = await bartender.owner()
        assert.equal(daiki_owner, bartender.address, 'Invalid daiki owner')
        assert.equal(bartender_owner, timelock.address, 'Invalid bartender owner')

        await expect(
            bartender.connect(deployer).add('1000', exampleToken.address, '0')
        ).to.be.revertedWith('Ownable: caller is not the owner')

        const eta = (await time.latest()).add(time.duration.hours(13)).toString();

        await timelock.connect(deployer).queueTransaction(
            bartender.address, '0', 'add(uint256,address,uint256)',
            encodeParameters(['uint256','address','uint256'], ['1000', exampleToken.address, '0']), eta
        )

        await time.increase(time.duration.hours(13))
        await timelock.connect(deployer).executeTransaction(
            bartender.address, '0', 'add(uint256,address,uint256)',
            encodeParameters(['uint256','address','uint256'], ['1000', exampleToken.address, '0']), eta
        )

        const poolInfo = await bartender.poolInfo(1)
        assert.equal(poolInfo.lpToken, exampleToken.address, 'Invalid lp token')
    })

})