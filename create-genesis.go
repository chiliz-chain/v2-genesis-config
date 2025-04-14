package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"io/ioutil"
	"math/big"
	"os"
	"reflect"
	"strings"
	"unicode"
	"unsafe"

	"time"

	"github.com/ethereum/go-ethereum/common/systemcontract"

	"github.com/ethereum/go-ethereum/common/math"

	_ "github.com/ethereum/go-ethereum/eth/tracers/native"

	"github.com/ethereum/go-ethereum/crypto"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/consensus"
	"github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/rawdb"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/ethdb/memorydb"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/trie"
)

type artifactData struct {
	Bytecode         string `json:"bytecode"`
	DeployedBytecode string `json:"deployedBytecode"`
}

func (a *artifactData) UnmarshalJSON(b []byte) error {
	var s struct {
		Bytecode struct {
			Object string `json:"object"`
		} `json:"bytecode"`
		DeployedBytecode struct {
			Object string `json:"object"`
		} `json:"deployedBytecode"`
	}
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}

	a.Bytecode = s.Bytecode.Object
	a.DeployedBytecode = s.DeployedBytecode.Object

	return nil
}

type dummyChainContext struct {
}

func (d *dummyChainContext) Engine() consensus.Engine {
	return nil
}

func (d *dummyChainContext) GetHeader(common.Hash, uint64) *types.Header {
	return nil
}

func createExtraData(validators []common.Address) []byte {
	extra := make([]byte, 32+20*len(validators)+65)
	for i, v := range validators {
		copy(extra[32+20*i:], v.Bytes())
	}
	return extra
}

func readDirtyStorageFromState(f *state.StateObject) state.Storage {
	var result map[common.Hash]common.Hash
	rs := reflect.ValueOf(*f)
	rf := rs.FieldByName("dirtyStorage")
	rs2 := reflect.New(rs.Type()).Elem()
	rs2.Set(rs)
	rf = rs2.FieldByName("dirtyStorage")
	rf = reflect.NewAt(rf.Type(), unsafe.Pointer(rf.UnsafeAddr())).Elem()
	ri := reflect.ValueOf(&result).Elem()
	ri.Set(rf)
	return result
}

func simulateSystemContract(genesis *core.Genesis, systemContract common.Address, rawArtifact []byte, constructor []byte, balance *big.Int) error {
	artifact := &artifactData{}
	if err := json.Unmarshal(rawArtifact, artifact); err != nil {
		return err
	}
	bytecode := append(hexutil.MustDecode(artifact.Bytecode), constructor...)
	// simulate constructor execution
	ethdb := rawdb.NewDatabase(memorydb.New())
	db := state.NewDatabaseWithConfig(ethdb, &trie.Config{})
	statedb, err := state.New(common.Hash{}, db, nil)
	if err != nil {
		return err
	}
	statedb.SetBalance(systemContract, balance)
	block := genesis.ToBlock()
	blockContext := core.NewEVMBlockContext(block.Header(), &dummyChainContext{}, &common.Address{})

	msg := &core.Message{
		From:              common.Address{},
		To:                &systemContract,
		Nonce:             0,
		Value:             big.NewInt(0),
		GasLimit:          10_000_000,
		GasPrice:          big.NewInt(0),
		Data:              []byte{},
		AccessList:        nil,
		SkipAccountChecks: false,
	}
	txContext := core.NewEVMTxContext(msg)
	if err != nil {
		return err
	}
	evm := vm.NewEVM(blockContext, txContext, statedb, genesis.Config, vm.Config{})
	deployedBytecode, _, err := evm.CreateWithAddress(vm.AccountRef(common.Address{}), bytecode, 10_000_000, big.NewInt(0), systemContract)
	if err != nil {
		for _, c := range deployedBytecode[64:] {
			if c >= 32 && c <= unicode.MaxASCII {
				print(string(c))
			}
		}
		println()
		return err
	}
	storage := readDirtyStorageFromState(statedb.GetOrNewStateObject(systemContract))
	// read state changes from state database
	genesisAccount := core.GenesisAccount{
		Code:    deployedBytecode,
		Storage: storage.Copy(),
		Balance: big.NewInt(0),
		Nonce:   0,
	}
	if genesis.Alloc == nil {
		genesis.Alloc = make(core.GenesisAlloc)
	}
	genesis.Alloc[systemContract] = genesisAccount
	// make sure ctor working fine (better to fail here instead of in consensus engine)
	errorCode, _, err := evm.Call(vm.AccountRef(common.Address{}), systemContract, hexutil.MustDecode("0xe1c7392a"), 10_000_000, big.NewInt(0))
	if err != nil {
		for _, c := range errorCode[64:] {
			if c >= 32 && c <= unicode.MaxASCII {
				print(string(c))
			}
		}
		println()
		return err
	}
	return nil
}

var stakingAddress = common.HexToAddress("0x0000000000000000000000000000000000001000")
var slashingIndicatorAddress = common.HexToAddress("0x0000000000000000000000000000000000001001")
var systemRewardAddress = common.HexToAddress("0x0000000000000000000000000000000000001002")
var stakingPoolAddress = common.HexToAddress("0x0000000000000000000000000000000000007001")
var governanceAddress = common.HexToAddress("0x0000000000000000000000000000000000007002")
var chainConfigAddress = common.HexToAddress("0x0000000000000000000000000000000000007003")
var runtimeUpgradeAddress = common.HexToAddress("0x0000000000000000000000000000000000007004")
var deployerProxyAddress = common.HexToAddress("0x0000000000000000000000000000000000007005")
var tokenomicsAddress = common.HexToAddress("0x0000000000000000000000000000000000007006")
var intermediarySystemAddress = common.HexToAddress("0xfffffffffffffffffffffffffffffffffffffffe")

//go:embed out/Staking.sol/Staking.json
var stakingRawArtifact []byte

//go:embed out/StakingPool.sol/StakingPool.json
var stakingPoolRawArtifact []byte

//go:embed out/ChainConfig.sol/ChainConfig.json
var chainConfigRawArtifact []byte

//go:embed out/SlashingIndicator.sol/SlashingIndicator.json
var slashingIndicatorRawArtifact []byte

//go:embed out/SystemReward.sol/SystemReward.json
var systemRewardRawArtifact []byte

//go:embed out/Governance.sol/Governance.json
var governanceRawArtifact []byte

//go:embed out/RuntimeUpgrade.sol/RuntimeUpgrade.json
var runtimeUpgradeRawArtifact []byte

//go:embed out/DeployerProxy.sol/DeployerProxy.json
var deployerProxyRawArtifact []byte

//go:embed out/Tokenomics.sol/Tokenomics.json
var tokenomicsRawArtifact []byte

func newArguments(typeNames ...string) abi.Arguments {
	var args abi.Arguments
	for i, tn := range typeNames {
		abiType, err := abi.NewType(tn, tn, nil)
		if err != nil {
			panic(err)
		}
		args = append(args, abi.Argument{Name: fmt.Sprintf("%d", i), Type: abiType})
	}
	return args
}

type consensusParams struct {
	ActiveValidatorsLength   uint32                `json:"activeValidatorsLength"`
	EpochBlockInterval       uint32                `json:"epochBlockInterval"`
	MisdemeanorThreshold     uint32                `json:"misdemeanorThreshold"`
	FelonyThreshold          uint32                `json:"felonyThreshold"`
	ValidatorJailEpochLength uint32                `json:"validatorJailEpochLength"`
	UndelegatePeriod         uint32                `json:"undelegatePeriod"`
	MinValidatorStakeAmount  *math.HexOrDecimal256 `json:"minValidatorStakeAmount"`
	MinStakingAmount         *math.HexOrDecimal256 `json:"minStakingAmount"`
}

type tokenomicsParams struct {
	StakingShare       uint16 `json:"stakingShare"`
	SystemRewardsShare uint16 `json:"systemRewardsShare"`
}

type ChilizForks struct {
	RuntimeUpgradeBlock    *math.HexOrDecimal256 `json:"runtimeUpgradeBlock"`
	DeployOriginBlock      *math.HexOrDecimal256 `json:"deployOriginBlock"`
	DeploymentHookFixBlock *math.HexOrDecimal256 `json:"deploymentHookFixBlock"`
	DeployerFactoryBlock   *math.HexOrDecimal256 `json:"deployerFactoryBlock"`
	Dragon8Time            uint64                `json:"dragon8Time,omitempty"`
	Dragon8FixTime         uint64                `json:"dragon8FixTime,omitempty"`
}

type genesisConfig struct {
	ChainId          int64                     `json:"chainId"`
	Deployers        []common.Address          `json:"deployers"`
	Validators       []common.Address          `json:"validators"`
	SystemTreasury   map[common.Address]uint16 `json:"systemTreasury"`
	ConsensusParams  consensusParams           `json:"consensusParams"`
	TokenomicsParams tokenomicsParams          `json:"tokenomicsParams"`
	VotingPeriod     int64                     `json:"votingPeriod"`
	Faucet           map[common.Address]string `json:"faucet"`
	CommissionRate   int64                     `json:"commissionRate"`
	InitialStakes    map[common.Address]string `json:"initialStakes"`
	Forks            ChilizForks               `json:"forks"`
}

func invokeConstructorOrPanic(genesis *core.Genesis, contract common.Address, rawArtifact []byte, typeNames []string, params []interface{}, silent bool, balance *big.Int) {
	ctor, err := newArguments(typeNames...).Pack(params...)
	if err != nil {
		panic(err)
	}
	sig := crypto.Keccak256([]byte(fmt.Sprintf("ctor(%s)", strings.Join(typeNames, ","))))[:4]
	ctor = append(sig, ctor...)
	ctor, err = newArguments("bytes").Pack(ctor)
	if err != nil {
		panic(err)
	}
	if !silent {
		fmt.Printf(" + calling constructor: address=%s sig=%s ctor=%s\n", contract.Hex(), hexutil.Encode(sig), hexutil.Encode(ctor))
	}
	if err := simulateSystemContract(genesis, contract, rawArtifact, ctor, balance); err != nil {
		panic(err)
	}
}

func createGenesisConfig(config genesisConfig, targetFile string, updateOnlyConfig bool) error {
	suppressLogging := targetFile == "stdout"
	var genesis *core.Genesis
	if updateOnlyConfig {
		genesis, _ = existingGenesisConfigOrDefault(config, targetFile, suppressLogging)
	} else {
		genesis = defaultGenesisConfig(config)
	}
	// extra data
	genesis.ExtraData = createExtraData(config.Validators)
	genesis.Config.Parlia.Epoch = uint64(config.ConsensusParams.EpochBlockInterval)
	// execute system contracts
	var initialStakes []*big.Int
	initialStakeTotal := big.NewInt(0)
	for _, v := range config.Validators {
		rawInitialStake, ok := config.InitialStakes[v]
		if !ok {
			return fmt.Errorf("initial stake is not found for validator: %s", v.Hex())
		}
		initialStake, err := hexutil.DecodeBig(rawInitialStake)
		if err != nil {
			return err
		}
		initialStakes = append(initialStakes, initialStake)
		initialStakeTotal.Add(initialStakeTotal, initialStake)
	}
	if genesis.Alloc == nil {
		invokeConstructorOrPanic(genesis, stakingAddress, stakingRawArtifact, []string{"address[]", "uint256[]", "uint16"}, []interface{}{
			config.Validators,
			initialStakes,
			uint16(config.CommissionRate),
		}, suppressLogging, initialStakeTotal)
		invokeConstructorOrPanic(genesis, chainConfigAddress, chainConfigRawArtifact, []string{"uint32", "uint32", "uint32", "uint32", "uint32", "uint32", "uint256", "uint256"}, []interface{}{
			config.ConsensusParams.ActiveValidatorsLength,
			config.ConsensusParams.EpochBlockInterval,
			config.ConsensusParams.MisdemeanorThreshold,
			config.ConsensusParams.FelonyThreshold,
			config.ConsensusParams.ValidatorJailEpochLength,
			config.ConsensusParams.UndelegatePeriod,
			(*big.Int)(config.ConsensusParams.MinValidatorStakeAmount),
			(*big.Int)(config.ConsensusParams.MinStakingAmount),
		}, suppressLogging, nil)
		invokeConstructorOrPanic(genesis, slashingIndicatorAddress, slashingIndicatorRawArtifact, []string{}, []interface{}{}, suppressLogging, nil)
		invokeConstructorOrPanic(genesis, stakingPoolAddress, stakingPoolRawArtifact, []string{}, []interface{}{}, suppressLogging, nil)
		var treasuryAddresses []common.Address
		var treasuryShares []uint16
		for k, v := range config.SystemTreasury {
			treasuryAddresses = append(treasuryAddresses, k)
			treasuryShares = append(treasuryShares, v)
		}
		invokeConstructorOrPanic(genesis, systemRewardAddress, systemRewardRawArtifact, []string{"address[]", "uint16[]"}, []interface{}{
			treasuryAddresses, treasuryShares,
		}, suppressLogging, nil)
		invokeConstructorOrPanic(genesis, governanceAddress, governanceRawArtifact, []string{"uint256"}, []interface{}{
			big.NewInt(config.VotingPeriod),
		}, suppressLogging, nil)
		invokeConstructorOrPanic(genesis, runtimeUpgradeAddress, runtimeUpgradeRawArtifact, []string{"address"}, []interface{}{
			systemcontract.EvmHookRuntimeUpgradeAddress,
		}, suppressLogging, nil)
		invokeConstructorOrPanic(genesis, deployerProxyAddress, deployerProxyRawArtifact, []string{"address[]"}, []interface{}{
			config.Deployers,
		}, suppressLogging, nil)
		invokeConstructorOrPanic(genesis, tokenomicsAddress, tokenomicsRawArtifact, []string{"uint16", "uint16"}, []interface{}{
			config.TokenomicsParams.StakingShare, config.TokenomicsParams.SystemRewardsShare,
		}, suppressLogging, nil)
		// create system contract
		genesis.Alloc[intermediarySystemAddress] = core.GenesisAccount{
			Balance: big.NewInt(0),
		}
		// set staking allocation
		stakingAlloc := genesis.Alloc[stakingAddress]
		stakingAlloc.Balance = initialStakeTotal
		genesis.Alloc[stakingAddress] = stakingAlloc
		// apply faucet
		for key, value := range config.Faucet {
			balance, ok := new(big.Int).SetString(value[2:], 16)
			if !ok {
				return fmt.Errorf("failed to parse number (%s)", value)
			}
			genesis.Alloc[key] = core.GenesisAccount{
				Balance: balance,
			}
		}
	}
	// save to file
	newJson, _ := json.MarshalIndent(genesis, "", "  ")
	if targetFile == "stdout" {
		_, err := os.Stdout.Write(newJson)
		return err
	} else if targetFile == "stderr" {
		_, err := os.Stderr.Write(newJson)
		return err
	}
	return ioutil.WriteFile(targetFile, newJson, fs.ModePerm)
}

func decimalToBigInt(value *math.HexOrDecimal256) *big.Int {
	if value == nil {
		return nil
	}
	return (*big.Int)(value)
}

func existingGenesisConfigOrDefault(config genesisConfig, existingGenesisFile string, silent bool) (*core.Genesis, bool) {
	bytes, err := os.ReadFile(existingGenesisFile)
	if err != nil {
		if !silent {
			fmt.Printf("WARN: failed to find existing genesis config (%s), re-creating", existingGenesisFile)
		}
		return defaultGenesisConfig(config), false
	}
	genesis := &core.Genesis{}
	if err := json.Unmarshal(bytes, genesis); err != nil {
		if !silent {
			fmt.Printf("ERR: failed to parse existing genesis config (%s), re-creating: %v", existingGenesisFile, err)
		}
		return defaultGenesisConfig(config), false
	}
	defaultConfig := defaultGenesisConfig(config)
	genesis.Config = defaultConfig.Config
	return genesis, true
}

func defaultGenesisConfig(config genesisConfig) *core.Genesis {
	chainConfig := &params.ChainConfig{
		ChainID: big.NewInt(config.ChainId),
		// Default ETH forks
		HomesteadBlock:      big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		MuirGlacierBlock:    big.NewInt(0),
		RamanujanBlock:      big.NewInt(0),
		NielsBlock:          big.NewInt(0),
		MirrorSyncBlock:     big.NewInt(0),
		BrunoBlock:          big.NewInt(0),
		// Chiliz V2 forks
		RuntimeUpgradeBlock:    decimalToBigInt(config.Forks.RuntimeUpgradeBlock),
		DeployOriginBlock:      decimalToBigInt(config.Forks.DeployOriginBlock),
		DeploymentHookFixBlock: decimalToBigInt(config.Forks.DeploymentHookFixBlock),
		DeployerFactoryBlock:   decimalToBigInt(config.Forks.DeployerFactoryBlock),
		Dragon8Time:            &config.Forks.Dragon8Time,
		Dragon8FixTime:         &config.Forks.Dragon8FixTime,

		// NEW FORKS
		// Ethereum forks
		BerlinBlock:       big.NewInt(0),
		LondonBlock:       big.NewInt(0),
		ArrowGlacierBlock: big.NewInt(0),
		GrayGlacierBlock:  big.NewInt(0),

		// BSC 2022 forks
		EulerBlock: nil,
		NanoBlock:  big.NewInt(0),
		MoranBlock: big.NewInt(0),
		GibbsBlock: big.NewInt(0),
		// BSC 2023 forks
		PlanckBlock:   big.NewInt(0),
		LubanBlock:    nil,
		PlatoBlock:    nil,
		HertzBlock:    big.NewInt(0),
		HertzfixBlock: big.NewInt(0),
		// BSC 2024 forks
		KeplerTime:   new(uint64),
		ShanghaiTime: new(uint64),

		// Parlia config
		Parlia: &params.ParliaConfig{
			Period: 3,
			// epoch length is managed by consensus params
		},
	}
	return &core.Genesis{
		Config:     chainConfig,
		Nonce:      0,
		Timestamp:  uint64(time.Now().Unix()),
		ExtraData:  nil,
		GasLimit:   0x2625a00,
		Difficulty: big.NewInt(0x01),
		Mixhash:    common.Hash{},
		Coinbase:   common.Address{},
		Alloc:      nil,
		Number:     0x00,
		GasUsed:    0x00,
		ParentHash: common.Hash{},
	}
}

var localNetConfig = genesisConfig{
	ChainId: 1337,
	// who is able to deploy smart contract from genesis block
	Deployers: []common.Address{
		common.HexToAddress("0x00a601f45688dba8a070722073b015277cf36725"),
	},
	// list of default validators
	Validators: []common.Address{
		common.HexToAddress("0x00a601f45688dba8a070722073b015277cf36725"),
	},
	SystemTreasury: map[common.Address]uint16{
		common.HexToAddress("0x00a601f45688dba8a070722073b015277cf36725"): 10000,
	},
	ConsensusParams: consensusParams{
		ActiveValidatorsLength:   25,                                                                    // suggested values are (3k+1, where k is honest validators, even better): 7, 13, 19, 25, 31...
		EpochBlockInterval:       20,                                                                    // better to use 1 day epoch (86400/3=28800, where 3s is block time)
		MisdemeanorThreshold:     5,                                                                     // after missing this amount of blocks per day validator losses all daily rewards (penalty)
		FelonyThreshold:          10,                                                                    // after missing this amount of blocks per day validator goes in jail for N epochs
		ValidatorJailEpochLength: 3,                                                                     // how many epochs validator should stay in jail (7 epochs = ~7 days)
		UndelegatePeriod:         2,                                                                     // allow claiming funds only after 6 epochs (~7 days)
		MinValidatorStakeAmount:  (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0xde0b6b3a7640000")),   // 1 ether
		MinStakingAmount:         (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0x1bc16d674ec800002")), // 1 ether
	},
	InitialStakes: map[common.Address]string{
		common.HexToAddress("0x00a601f45688dba8a070722073b015277cf36725"): "0x3635c9adc5dea00000", // 1000 eth
	},
	TokenomicsParams: tokenomicsParams{
		StakingShare:       6500,
		SystemRewardsShare: 3500,
	},
	// owner of the governance
	VotingPeriod: 20, // 1 minute
	// faucet
	Faucet: map[common.Address]string{
		common.HexToAddress("0x00a601f45688dba8a070722073b015277cf36725"): "0x21e19e0c9bab2400000",
		common.HexToAddress("0x57BA24bE2cF17400f37dB3566e839bfA6A2d018a"): "0x21e19e0c9bab2400000",
		common.HexToAddress("0xAc55Ad39532e7E609DDa1FFfA7F0B6D796dcB049"): "0x21e19e0c9bab2400000",
	},
	Forks: ChilizForks{
		RuntimeUpgradeBlock:    (*math.HexOrDecimal256)(big.NewInt(0)),
		DeployOriginBlock:      (*math.HexOrDecimal256)(big.NewInt(0)),
		DeploymentHookFixBlock: (*math.HexOrDecimal256)(big.NewInt(0)),
		DeployerFactoryBlock:   (*math.HexOrDecimal256)(big.NewInt(0)),
		Dragon8Time:            uint64(time.Now().Unix()),
		Dragon8FixTime:         uint64(time.Now().Unix()),
	},
}

var devNetConfig = genesisConfig{
	ChainId: 17243,
	// who is able to deploy smart contract from genesis block (it won't generate event log)
	Deployers: []common.Address{},
	// list of default validators (it won't generate event log)
	Validators: []common.Address{
		common.HexToAddress("0x08fae3885e299c24ff9841478eb946f41023ac69"),
		common.HexToAddress("0x751aaca849b09a3e347bbfe125cf18423cc24b40"),
		common.HexToAddress("0xa6ff33e3250cc765052ac9d7f7dfebda183c4b9b"),
		common.HexToAddress("0x49c0f7c8c11a4c80dc6449efe1010bb166818da8"),
		common.HexToAddress("0x8e1ea6eaa09c3b40f4a51fcd056a031870a0549a"),
	},
	SystemTreasury: map[common.Address]uint16{
		common.HexToAddress("0x0000000000000000000000000000000000000000"): 10000,
	},
	ConsensusParams: consensusParams{
		ActiveValidatorsLength:   25,   // suggested values are (3k+1, where k is honest validators, even better): 7, 13, 19, 25, 31...
		EpochBlockInterval:       1200, // better to use 1 day epoch (86400/3=28800, where 3s is block time)
		MisdemeanorThreshold:     50,   // after missing this amount of blocks per day validator losses all daily rewards (penalty)
		FelonyThreshold:          150,  // after missing this amount of blocks per day validator goes in jail for N epochs
		ValidatorJailEpochLength: 7,    // how many epochs validator should stay in jail (7 epochs = ~7 days)
		UndelegatePeriod:         6,    // allow claiming funds only after 6 epochs (~7 days)

		MinValidatorStakeAmount: (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0xde0b6b3a7640000")), // how many tokens validator must stake to create a validator (in ether)
		MinStakingAmount:        (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0xde0b6b3a7640000")), // minimum staking amount for delegators (in ether)
	},
	InitialStakes: map[common.Address]string{
		common.HexToAddress("0x08fae3885e299c24ff9841478eb946f41023ac69"): "0x3635c9adc5dea00000", // 1000 eth
		common.HexToAddress("0x751aaca849b09a3e347bbfe125cf18423cc24b40"): "0x3635c9adc5dea00000", // 1000 eth
		common.HexToAddress("0xa6ff33e3250cc765052ac9d7f7dfebda183c4b9b"): "0x3635c9adc5dea00000", // 1000 eth
		common.HexToAddress("0x49c0f7c8c11a4c80dc6449efe1010bb166818da8"): "0x3635c9adc5dea00000", // 1000 eth
		common.HexToAddress("0x8e1ea6eaa09c3b40f4a51fcd056a031870a0549a"): "0x3635c9adc5dea00000", // 1000 eth
	},
	// owner of the governance
	VotingPeriod: 60, // 3 minutes
	// faucet
	Faucet: map[common.Address]string{
		common.HexToAddress("0x00a601f45688dba8a070722073b015277cf36725"): "0x21e19e0c9bab2400000",    // governance
		common.HexToAddress("0xb891fe7b38f857f53a7b5529204c58d5c487280b"): "0x52b7d2dcc80cd2e4000000", // faucet (10kk)
	},
}

var testNetConfig = genesisConfig{
	ChainId: 88880,
	// who is able to deploy smart contract from genesis block (it won't generate event log)
	Deployers: []common.Address{
		common.HexToAddress("0x54E98ee51446505fcf69093E015Ee36034321104"),
	},
	// list of default validators (it won't generate event log)
	Validators: []common.Address{
		common.HexToAddress("0x86d12897C56Fe1dB08BDfB84Bc90f458ee7dC5cE"),
		common.HexToAddress("0xE45D81a7EF9456A254aa4db010AAF6601a15B5B7"),
		common.HexToAddress("0x76106F0857938684D24f2CE167EE11607dFaa57d"),
		common.HexToAddress("0x48223C151df5dc1dBc2E24f17e77728358113705"),
		common.HexToAddress("0x49CfDafF386FD2683d28678aBd53F11Dec23c76C"),
	},
	SystemTreasury: map[common.Address]uint16{
		common.HexToAddress("0xde8712be934a6A4C7dDd17DC91669F51284f4b0c"): 10000,
	},
	ConsensusParams: consensusParams{
		ActiveValidatorsLength:   5,
		EpochBlockInterval:       1200,                                                                   // (~1hour)
		MisdemeanorThreshold:     100,                                                                    // missed blocks per epoch
		FelonyThreshold:          200,                                                                    // missed blocks per epoch
		ValidatorJailEpochLength: 6,                                                                      // nb of epochs
		UndelegatePeriod:         1,                                                                      // nb of epochs
		MinValidatorStakeAmount:  (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0x3635c9adc5dea00000")), // how many tokens validator must stake to create a validator (in ether)
		MinStakingAmount:         (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0xde0b6b3a7640000")),    // minimum staking amount for delegators (in ether)
	},
	InitialStakes: map[common.Address]string{
		common.HexToAddress("0x86d12897C56Fe1dB08BDfB84Bc90f458ee7dC5cE"): "0x152D02C7E14AF6800000", // 100 000 eth
		common.HexToAddress("0xE45D81a7EF9456A254aa4db010AAF6601a15B5B7"): "0x3635C9ADC5DEA00000",   // 1000 eth
		common.HexToAddress("0x76106F0857938684D24f2CE167EE11607dFaa57d"): "0x3635C9ADC5DEA00000",   // 1000 eth
		common.HexToAddress("0x48223C151df5dc1dBc2E24f17e77728358113705"): "0x3635C9ADC5DEA00000",   // 1000 eth
		common.HexToAddress("0x49CfDafF386FD2683d28678aBd53F11Dec23c76C"): "0x2B5E3AF16B1880000",    // 50 eth
	},
	// owner of the governance
	VotingPeriod: 1200, // (~1hour)
	// faucet
	Faucet: map[common.Address]string{
		common.HexToAddress("0xb0c09bF51E04eDc7Bf198D61bB74CDa886878167"): "0x197D7361310E45C669F80000", // main
		common.HexToAddress("0xc59181b702A7F3A8eCea27f30072B8dbCcC0c48a"): "0x33B2E3C9FD0803CE8000000",  // faucet
	},
	Forks: ChilizForks{
		RuntimeUpgradeBlock:    (*math.HexOrDecimal256)(big.NewInt(0)),
		DeployOriginBlock:      (*math.HexOrDecimal256)(big.NewInt(2849000)),
		DeploymentHookFixBlock: (*math.HexOrDecimal256)(big.NewInt(6067300)),
		DeployerFactoryBlock:   nil,
	},
}

var spicyConfig = genesisConfig{
	ChainId: 88882,
	// who is able to deploy smart contract from genesis block (it won't generate event log)
	Deployers: []common.Address{
		common.HexToAddress("0x02880217b082cC24D371eB5Bad0827D208bcBC6D"),
	},
	// list of default validators (it won't generate event log)
	Validators: []common.Address{
		common.HexToAddress("0xb1b5a8b8E2a263C0F497BC32a7cb6D27AEA921fc"),
		common.HexToAddress("0x4dD74707f22b74EC872CA6AEB2a065E3d006B9d9"),
		common.HexToAddress("0xBD6D190548bbF5C6920a826dF063A970Bd18f307"),
		common.HexToAddress("0xeC2e502f77c4811f2ef477397235976b1371FCd3"),
		common.HexToAddress("0x1cB3FC9e10fB5b845e53e5EaAE0bD561e662b0A5"),
		common.HexToAddress("0xbdBF08393b66130B4b243863150A265b2A5Df642"),
		common.HexToAddress("0x86f2BB174c450917A1b560c66525E64A1c9B6a04"),
	},
	SystemTreasury: map[common.Address]uint16{
		common.HexToAddress("0x060eA461Cf7E78A38400dE9255687beb9b2c7298"): 10000,
	},
	ConsensusParams: consensusParams{
		ActiveValidatorsLength:   5,
		EpochBlockInterval:       7200,                                                                   // ~6 hours
		MisdemeanorThreshold:     400,                                                                    // missed blocks per epoch
		FelonyThreshold:          800,                                                                    // missed blocks per epoch
		ValidatorJailEpochLength: 4,                                                                      // nb of epochs
		UndelegatePeriod:         1,                                                                      // nb of epochs
		MinValidatorStakeAmount:  (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0x3635c9adc5dea00000")), // how many tokens validator must stake to create a validator (in ether)
		MinStakingAmount:         (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0xde0b6b3a7640000")),    // minimum staking amount for delegators (in ether)
	},
	InitialStakes: map[common.Address]string{
		common.HexToAddress("0xb1b5a8b8E2a263C0F497BC32a7cb6D27AEA921fc"): "0x152D02C7E14AF6800000", // 100 000 CHZ
		common.HexToAddress("0x4dD74707f22b74EC872CA6AEB2a065E3d006B9d9"): "0x3635C9ADC5DEA00000",   // 1000 CHZ
		common.HexToAddress("0xBD6D190548bbF5C6920a826dF063A970Bd18f307"): "0x3635C9ADC5DEA00000",   // 1000 CHZ
		common.HexToAddress("0xeC2e502f77c4811f2ef477397235976b1371FCd3"): "0x3635C9ADC5DEA00000",   // 1000 CHZ
		common.HexToAddress("0x1cB3FC9e10fB5b845e53e5EaAE0bD561e662b0A5"): "0x3635C9ADC5DEA00000",   // 1000 CHZ
		common.HexToAddress("0xbdBF08393b66130B4b243863150A265b2A5Df642"): "0x3635C9ADC5DEA00000",   // 1000 CHZ
		common.HexToAddress("0x86f2BB174c450917A1b560c66525E64A1c9B6a04"): "0x3635C9ADC5DEA00000",   // 1000 CHZ
	},
	VotingPeriod: 1200, // (~1hour)
	// faucet
	Faucet: map[common.Address]string{
		common.HexToAddress("0x77c6DC8fC511Bf2Fa594c47DdC336C69D745e73A"): "0x197D7361310E45C669F80000", // main
		common.HexToAddress("0xa6779032c48127f362244AADD80E3A6E1b50BA93"): "0x33B2E3C9FD0803CE8000000",  // faucet
	},
	Forks: ChilizForks{
		RuntimeUpgradeBlock:    (*math.HexOrDecimal256)(big.NewInt(0)),
		DeployOriginBlock:      (*math.HexOrDecimal256)(big.NewInt(0)),
		DeploymentHookFixBlock: (*math.HexOrDecimal256)(big.NewInt(0)),
		DeployerFactoryBlock:   nil,
	},
}

var mainNetConfig = genesisConfig{
	ChainId: 88888,
	// who is able to deploy smart contract from genesis block (it won't generate event log)
	Deployers: []common.Address{
		common.HexToAddress("0xfe74A701E42670fc23b64f8C4FaC59a0A01e6aA3"),
	},
	// list of default validators (it won't generate event log)
	Validators: []common.Address{
		common.HexToAddress("0x2045A60c9BFFCCEEB5a1AAD0e22A75965d221882"),
		common.HexToAddress("0x811ceF18Ac8b28e0c4A54aB8220a51897ba9C489"),
		common.HexToAddress("0x4d466f3A688Cb1096497dbcB9Fd68E500e24f0B1"),
		common.HexToAddress("0x5c12a44A0bbaaF133123895cf90e05d94D6137Dc"),
		common.HexToAddress("0x64552Cb88DE4Cd7438bFc6b8d4757305C6FA96Ae"),
		common.HexToAddress("0xE548F293E2BA625eFB34c11e43217dD4330D6da8"),
		common.HexToAddress("0xA2ec78Eb13C40c03F3F9283f7057B6C7E652F644"),
		common.HexToAddress("0x7486B4f8f036B4Df55f7a55ab9b61D6d605067c6"),
		common.HexToAddress("0xf57c7a5BCB023aB18683A46fA25a00fB19d651bE"),
		common.HexToAddress("0xE0efCc3Fb5B1c66257945Ebc533C101783Fe97b4"),
		common.HexToAddress("0x39a7179B6c73622B63B8b58b973835e00E9d38b4"),
		common.HexToAddress("0x2064F56684377A8C50F4CdfBD5C65873763143fb"),
		common.HexToAddress("0xe5cFf8f16dA0b3067BC7432ba2b4AE7199EAAE53"),
		common.HexToAddress("0x52527E4b47ad69Cd69021fBB6dA2A4F210FEec62"),
		common.HexToAddress("0x31Dd5A7429ae591D2d73935C001DD148faBDd2cf"),
	},
	SystemTreasury: map[common.Address]uint16{
		common.HexToAddress("0xFddAc11E0072e3377775345D58de0dc88A964837"): 10000,
	},
	ConsensusParams: consensusParams{
		ActiveValidatorsLength:   11,
		EpochBlockInterval:       28800,                                                                     // 1 day
		MisdemeanorThreshold:     14400,                                                                     // missed blocks per epoch
		FelonyThreshold:          21600,                                                                     // missed blocks per epoch
		ValidatorJailEpochLength: 7,                                                                         // nb of epochs
		UndelegatePeriod:         7,                                                                         // nb of epochs
		MinValidatorStakeAmount:  (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0x84595161401484A000000")), // how many tokens validator must stake to create a validator (in ether) - 10,000,000
		MinStakingAmount:         (*math.HexOrDecimal256)(hexutil.MustDecodeBig("0x56BC75E2D63100000")),     // minimum staking amount for delegators (in CHZ) - 100
	},
	VotingPeriod: 271600, // 7 days
	InitialStakes: map[common.Address]string{
		common.HexToAddress("0x2045A60c9BFFCCEEB5a1AAD0e22A75965d221882"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x811ceF18Ac8b28e0c4A54aB8220a51897ba9C489"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x4d466f3A688Cb1096497dbcB9Fd68E500e24f0B1"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x5c12a44A0bbaaF133123895cf90e05d94D6137Dc"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x64552Cb88DE4Cd7438bFc6b8d4757305C6FA96Ae"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0xE548F293E2BA625eFB34c11e43217dD4330D6da8"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0xA2ec78Eb13C40c03F3F9283f7057B6C7E652F644"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x7486B4f8f036B4Df55f7a55ab9b61D6d605067c6"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0xf57c7a5BCB023aB18683A46fA25a00fB19d651bE"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0xE0efCc3Fb5B1c66257945Ebc533C101783Fe97b4"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x39a7179B6c73622B63B8b58b973835e00E9d38b4"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x2064F56684377A8C50F4CdfBD5C65873763143fb"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0xe5cFf8f16dA0b3067BC7432ba2b4AE7199EAAE53"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x52527E4b47ad69Cd69021fBB6dA2A4F210FEec62"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
		common.HexToAddress("0x31Dd5A7429ae591D2d73935C001DD148faBDd2cf"): "0x84595161401484A000000", // Validator 10,000,000 CHZ
	},
	// Supply Distribution
	Faucet: map[common.Address]string{
		common.HexToAddress("0xFddAc11E0072e3377775345D58de0dc88A964837"): "0x1C3CA1E1AAC1A93AF8800000", // Treasury 8,738,880,288 eth
		common.HexToAddress("0xfe74A701E42670fc23b64f8C4FaC59a0A01e6aA3"): "0x56BC75E2D63100000",        // Deployer 100 CHZ
		common.HexToAddress("0x8ee1c1f4b14c0A1698BdA02f58021968010523D2"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0xf9768B0Ac91F4B27f7F4DC88574a050c0e13Ccc1"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x97ADd7226B3f1020fB3308cc67e74cb77757C211"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x72676b2A2371Af4Fe23515e0E8bE9d44Bf41A6f4"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0xb67D0e9394932d3cFa6102A55F636481FBcc7976"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x92D00DA3aE5f01761f5e1f425AFe3322931AAd31"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0xF25E764a2222532008D89FC018E70c18DD2401C2"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x4e4620FE9dF2751F55FA01D24413343290c22698"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0xf299AfC34ec0B9dCAF868914288d735149d6306f"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x9a905C99D7753F01918E389C785b5862CF7A3945"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x19d0bc6d0Ca394E3547fF06A0F2805dB623dEcA8"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x7F420438941EB35bCe2E7C6824B8f9c04Ad4f188"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0xdC3A7153A2afB491B94784d86d6A915Ce5dde102"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x8a999c490793f9d340Be71Ea4Ae81E9C627bD0cd"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x6d25F93FAb44a7651dd52B3560ac74d98e1f912C"): "0x56BC75E2D63100000",        // Validator owner 100 CHZ
		common.HexToAddress("0x4b045692540E6B7AfDE44cdad60136d170efc623"): "0x3635C9ADC5DEA00000",       // Bridge relayer 1,000 CHZ
		common.HexToAddress("0xb0AdF650ABDc7d2d5ac7366888ab492e9Df8589A"): "0x3635C9ADC5DEA00000",       // Bridge relayer 1,000 CHZ
		common.HexToAddress("0x52f30AefB50B5d271d93A10730088733Bdbe31E0"): "0x3635C9ADC5DEA00000",       // Bridge relayer 1,000 CHZ
		common.HexToAddress("0x1Cb83A71d81DaCe297975e377777c94a32d9D5dD"): "0x3635C9ADC5DEA00000",       // Bridge relayer 1,000 CHZ
		common.HexToAddress("0xAE68F408160C40d508834734aC5bEd773a36e9D2"): "0x3635C9ADC5DEA00000",       // Bridge relayer 1,000 CHZ
		common.HexToAddress("0x3665dfcdaf8310684c24592b017D986A993320e6"): "0x3635C9ADC5DEA00000",       // Bridge relayer 1,000 CHZ
		common.HexToAddress("0x252B5CA6c838ae47508c1eA72Dd73b58c607Af0f"): "0x3635C9ADC5DEA00000",       // Bridge relayer 1,000 CHZ
	},
	Forks: ChilizForks{
		RuntimeUpgradeBlock:    (*math.HexOrDecimal256)(big.NewInt(0)),
		DeployOriginBlock:      (*math.HexOrDecimal256)(big.NewInt(0)),
		DeploymentHookFixBlock: (*math.HexOrDecimal256)(big.NewInt(0)),
		DeployerFactoryBlock:   nil, // TODO: "specify fork block here"
	},
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		fileContents, err := os.ReadFile(args[0])
		if err != nil {
			panic(err)
		}
		genesis := &genesisConfig{}
		err = json.Unmarshal(fileContents, genesis)
		if err != nil {
			panic(err)
		}
		outputFile := "stdout"
		if len(args) > 1 {
			outputFile = args[1]
		}
		err = createGenesisConfig(*genesis, outputFile, false)
		if err != nil {
			panic(err)
		}
		return
	}
	fmt.Printf("building localnet\n")
	if err := createGenesisConfig(localNetConfig, "localnet.json", false); err != nil {
		panic(err)
	}
	fmt.Printf("\nbuilding devnet\n")
	if err := createGenesisConfig(devNetConfig, "devnet.json", false); err != nil {
		panic(err)
	}
	fmt.Printf("\nbuilding scoville testnet\n")
	if err := createGenesisConfig(testNetConfig, "testnet.json", true); err != nil {
		panic(err)
	}
	fmt.Printf("\nbuilding spicy testnet\n")
	if err := createGenesisConfig(spicyConfig, "spicy.json", true); err != nil {
		panic(err)
	}
	fmt.Printf("\nbuilding mainnet\n")
	if err := createGenesisConfig(mainNetConfig, "mainnet.json", true); err != nil {
		panic(err)
	}
	fmt.Printf("\n")
}
