import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  console.log("\n🚀 Deploying Canteen contract...");
  console.log(`Deployer: ${deployer}`);

  const deployedCanteen = await deploy("Canteen", {
    from: deployer,
    log: true,
    args: [], // Canteen constructor has no arguments
  });

  console.log(`\n✅ Canteen contract deployed at: ${deployedCanteen.address}`);
  console.log(`   Transaction hash: ${deployedCanteen.transactionHash}`);
  console.log(`   Gas used: ${deployedCanteen.receipt?.gasUsed}`);
};

export default func;
func.id = "deploy_canteen";
func.tags = ["Canteen"];
