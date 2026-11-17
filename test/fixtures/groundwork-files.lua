-- test/fixtures/groundwork-files.lua
-- A scenes file, a PSET and the PSET's five side files as this build (the
-- groundwork before 3.8, package 4a) writes them, for
-- test/unit/system_37_test.lua (format 9's files loading as saved; the
-- groundwork plan's ruling 2). Each value is the file's text, byte for byte,
-- but for two substitutions: the PSET's buf<n>_file lines held the
-- recording's temporary audio folder, written here as @AUDIO@, and the
-- scenes file's pset field held the recording's data folder before
-- strata-05, written here as @DATA@ (the test puts its own folders there).
--
-- How it was recorded (2026-11-17), by the method of
-- test/fixtures/3.6.0-files.lua's header: in the package's own worktree, a
-- throwaway unit file (never committed) run as `lua test/run.lua <its
-- filter>` (Lua 5.3.6), then deleted. Everything was set through the
-- build's own code. The file seeds math.randomseed(39), runs
-- h.load_strata() and h.finish_startup(context), then sets a state:
-- h.scramble_state(39); v1_source 2 (buffer 1) and v1_buf_scan 0.5; voice
-- 2's step 3 at level 9 with prob 40, notes {0, 7} and ratchet 3; LFO 1 on
-- with its home on v2_main (S.lib.matrix.set_home) and depth 40, and LFO
-- 2's home on reverb_mix; macro 1's first target reverb_mix 0.2-0.8; matrix
-- routing 1 from macro1 to v3_grain_pitch at depth 40. It captures scene 1,
-- then runs h.scramble_state(40), captures scene 4 and names it "four"
-- (S.lib.scenes.set_name, which writes the live file). It writes the PSET
-- with params:write(<data>/strata-05.pset, "groundwork"), which writes the
-- five side files and names the PSET in the live file. scenes.data is the
-- data folder's strata/scenes.data after that, and the other six are the
-- strata-05.* files.
return {
  ["scenes.data"] = [==[
return {
-- Table: {1}
{
   ["pset"]="@DATA@strata-05",
   ["scenes"]={2},
   ["version"]=9,
},
-- Table: {2}
{
   {3},
   {4},
   {5},
   {6},
   {7},
   {8},
   {9},
   {10},
   {11},
   {12},
   {13},
   {14},
   {15},
   {16},
   {17},
   {18},
},
-- Table: {3}
{
   ["data"]={19},
   ["name"]="",
   ["populated"]=true,
},
-- Table: {4}
{
   ["data"]={20},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {5}
{
   ["data"]={21},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {6}
{
   ["data"]={22},
   ["name"]="four",
   ["populated"]=true,
},
-- Table: {7}
{
   ["data"]={23},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {8}
{
   ["data"]={24},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {9}
{
   ["data"]={25},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {10}
{
   ["data"]={26},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {11}
{
   ["data"]={27},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {12}
{
   ["data"]={28},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {13}
{
   ["data"]={29},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {14}
{
   ["data"]={30},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {15}
{
   ["data"]={31},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {16}
{
   ["data"]={32},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {17}
{
   ["data"]={33},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {18}
{
   ["data"]={34},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {19}
{
   ["delay_division"]=7,
   ["delay_feedback"]=0.4,
   ["delay_mix"]=0.0,
   ["delay_pingpong"]=0.0,
   ["delay_sync"]=0,
   ["delay_time"]=0.375,
   ["drift_amount"]=0.01,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["gesture_1_play"]=0,
   ["gesture_2_play"]=0,
   ["gesture_3_play"]=0,
   ["gesture_4_play"]=0,
   ["locked"]={35},
   ["macro_1"]=0,
   ["macro_10"]=0,
   ["macro_11"]=0,
   ["macro_12"]=0,
   ["macro_13"]=0,
   ["macro_14"]=0,
   ["macro_15"]=0,
   ["macro_16"]=0,
   ["macro_2"]=0,
   ["macro_3"]=0,
   ["macro_4"]=0,
   ["macro_5"]=0,
   ["macro_6"]=0,
   ["macro_7"]=0,
   ["macro_8"]=0,
   ["macro_9"]=0,
   ["macros"]={36},
   ["master_density"]=1.0,
   ["matrix"]={37},
   ["matrix_1"]=1,
   ["matrix_10"]=1,
   ["matrix_10_depth"]=0,
   ["matrix_11"]=1,
   ["matrix_11_depth"]=0,
   ["matrix_12"]=1,
   ["matrix_12_depth"]=0,
   ["matrix_13"]=1,
   ["matrix_13_depth"]=0,
   ["matrix_14"]=1,
   ["matrix_14_depth"]=0,
   ["matrix_15"]=1,
   ["matrix_15_depth"]=0,
   ["matrix_16"]=1,
   ["matrix_16_depth"]=0,
   ["matrix_1_depth"]=40,
   ["matrix_2"]=1,
   ["matrix_2_depth"]=0,
   ["matrix_3"]=1,
   ["matrix_3_depth"]=0,
   ["matrix_4"]=1,
   ["matrix_4_depth"]=0,
   ["matrix_5"]=1,
   ["matrix_5_depth"]=0,
   ["matrix_6"]=1,
   ["matrix_6_depth"]=0,
   ["matrix_7"]=1,
   ["matrix_7_depth"]=0,
   ["matrix_8"]=1,
   ["matrix_8_depth"]=0,
   ["matrix_9"]=1,
   ["matrix_9_depth"]=0,
   ["mutation_amount"]=0.25,
   ["mutation_enabled"]=0,
   ["mutation_probability"]=0.15,
   ["mutation_rate"]=2.0,
   ["patterns"]={38},
   ["reverb_damp"]=0.5,
   ["reverb_mix"]=0.3,
   ["reverb_size"]=0.8,
   ["root"]=1,
   ["scale"]=1,
   ["scatter"]=0,
   ["scatter_amp"]=0,
   ["scatter_cutoff"]=0,
   ["scatter_depth"]=10,
   ["scatter_pitch"]=1,
   ["scatter_pos"]=1,
   ["scatter_rate"]=0.1,
   ["scatter_size"]=0,
   ["sequences"]={39},
   ["steps"]={40},
   ["strata_lfo1"]=1,
   ["strata_lfo1_depth"]=40,
   ["strata_lfo1_depth_mod"]=1,
   ["strata_lfo1_depth_mod_amt"]=0,
   ["strata_lfo1_division"]=13,
   ["strata_lfo1_mode"]=1,
   ["strata_lfo1_offset"]=0,
   ["strata_lfo1_phase"]=0,
   ["strata_lfo1_rate"]=0.25,
   ["strata_lfo1_rate_mod"]=1,
   ["strata_lfo1_rate_mod_amt"]=0,
   ["strata_lfo1_shape"]=1,
   ["strata_lfo2"]=0,
   ["strata_lfo2_depth"]=25,
   ["strata_lfo2_depth_mod"]=1,
   ["strata_lfo2_depth_mod_amt"]=0,
   ["strata_lfo2_division"]=13,
   ["strata_lfo2_mode"]=1,
   ["strata_lfo2_offset"]=0,
   ["strata_lfo2_phase"]=0,
   ["strata_lfo2_rate"]=0.25,
   ["strata_lfo2_rate_mod"]=1,
   ["strata_lfo2_rate_mod_amt"]=0,
   ["strata_lfo2_shape"]=1,
   ["strata_lfo3"]=0,
   ["strata_lfo3_depth"]=25,
   ["strata_lfo3_depth_mod"]=1,
   ["strata_lfo3_depth_mod_amt"]=0,
   ["strata_lfo3_division"]=13,
   ["strata_lfo3_mode"]=1,
   ["strata_lfo3_offset"]=0,
   ["strata_lfo3_phase"]=0,
   ["strata_lfo3_rate"]=0.25,
   ["strata_lfo3_rate_mod"]=1,
   ["strata_lfo3_rate_mod_amt"]=0,
   ["strata_lfo3_shape"]=1,
   ["strata_lfo4"]=0,
   ["strata_lfo4_depth"]=25,
   ["strata_lfo4_depth_mod"]=1,
   ["strata_lfo4_depth_mod_amt"]=0,
   ["strata_lfo4_division"]=13,
   ["strata_lfo4_mode"]=1,
   ["strata_lfo4_offset"]=0,
   ["strata_lfo4_phase"]=0,
   ["strata_lfo4_rate"]=0.25,
   ["strata_lfo4_rate_mod"]=1,
   ["strata_lfo4_rate_mod_amt"]=0,
   ["strata_lfo4_shape"]=1,
   ["strata_lfo5"]=0,
   ["strata_lfo5_depth"]=25,
   ["strata_lfo5_depth_mod"]=1,
   ["strata_lfo5_depth_mod_amt"]=0,
   ["strata_lfo5_division"]=13,
   ["strata_lfo5_mode"]=1,
   ["strata_lfo5_offset"]=0,
   ["strata_lfo5_phase"]=0,
   ["strata_lfo5_rate"]=0.25,
   ["strata_lfo5_rate_mod"]=1,
   ["strata_lfo5_rate_mod_amt"]=0,
   ["strata_lfo5_shape"]=1,
   ["strata_lfo6"]=0,
   ["strata_lfo6_depth"]=25,
   ["strata_lfo6_depth_mod"]=1,
   ["strata_lfo6_depth_mod_amt"]=0,
   ["strata_lfo6_division"]=13,
   ["strata_lfo6_mode"]=1,
   ["strata_lfo6_offset"]=0,
   ["strata_lfo6_phase"]=0,
   ["strata_lfo6_rate"]=0.25,
   ["strata_lfo6_rate_mod"]=1,
   ["strata_lfo6_rate_mod_amt"]=0,
   ["strata_lfo6_shape"]=1,
   ["tempo"]=120,
   ["voices"]={41},
},
-- Table: {20}
{
},
-- Table: {21}
{
},
-- Table: {22}
{
   ["delay_division"]=7,
   ["delay_feedback"]=0.4,
   ["delay_mix"]=0.0,
   ["delay_pingpong"]=0.0,
   ["delay_sync"]=0,
   ["delay_time"]=0.375,
   ["drift_amount"]=0.01,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["gesture_1_play"]=0,
   ["gesture_2_play"]=0,
   ["gesture_3_play"]=0,
   ["gesture_4_play"]=0,
   ["locked"]={42},
   ["macro_1"]=0,
   ["macro_10"]=0,
   ["macro_11"]=0,
   ["macro_12"]=0,
   ["macro_13"]=0,
   ["macro_14"]=0,
   ["macro_15"]=0,
   ["macro_16"]=0,
   ["macro_2"]=0,
   ["macro_3"]=0,
   ["macro_4"]=0,
   ["macro_5"]=0,
   ["macro_6"]=0,
   ["macro_7"]=0,
   ["macro_8"]=0,
   ["macro_9"]=0,
   ["macros"]={43},
   ["master_density"]=1.0,
   ["matrix"]={44},
   ["matrix_1"]=1,
   ["matrix_10"]=1,
   ["matrix_10_depth"]=0,
   ["matrix_11"]=1,
   ["matrix_11_depth"]=0,
   ["matrix_12"]=1,
   ["matrix_12_depth"]=0,
   ["matrix_13"]=1,
   ["matrix_13_depth"]=0,
   ["matrix_14"]=1,
   ["matrix_14_depth"]=0,
   ["matrix_15"]=1,
   ["matrix_15_depth"]=0,
   ["matrix_16"]=1,
   ["matrix_16_depth"]=0,
   ["matrix_1_depth"]=40,
   ["matrix_2"]=1,
   ["matrix_2_depth"]=0,
   ["matrix_3"]=1,
   ["matrix_3_depth"]=0,
   ["matrix_4"]=1,
   ["matrix_4_depth"]=0,
   ["matrix_5"]=1,
   ["matrix_5_depth"]=0,
   ["matrix_6"]=1,
   ["matrix_6_depth"]=0,
   ["matrix_7"]=1,
   ["matrix_7_depth"]=0,
   ["matrix_8"]=1,
   ["matrix_8_depth"]=0,
   ["matrix_9"]=1,
   ["matrix_9_depth"]=0,
   ["mutation_amount"]=0.25,
   ["mutation_enabled"]=0,
   ["mutation_probability"]=0.15,
   ["mutation_rate"]=2.0,
   ["patterns"]={45},
   ["reverb_damp"]=0.5,
   ["reverb_mix"]=0.3,
   ["reverb_size"]=0.8,
   ["root"]=1,
   ["scale"]=1,
   ["scatter"]=0,
   ["scatter_amp"]=0,
   ["scatter_cutoff"]=0,
   ["scatter_depth"]=10,
   ["scatter_pitch"]=1,
   ["scatter_pos"]=1,
   ["scatter_rate"]=0.1,
   ["scatter_size"]=0,
   ["sequences"]={46},
   ["steps"]={47},
   ["strata_lfo1"]=1,
   ["strata_lfo1_depth"]=40,
   ["strata_lfo1_depth_mod"]=1,
   ["strata_lfo1_depth_mod_amt"]=0,
   ["strata_lfo1_division"]=13,
   ["strata_lfo1_mode"]=1,
   ["strata_lfo1_offset"]=0,
   ["strata_lfo1_phase"]=0,
   ["strata_lfo1_rate"]=0.25,
   ["strata_lfo1_rate_mod"]=1,
   ["strata_lfo1_rate_mod_amt"]=0,
   ["strata_lfo1_shape"]=1,
   ["strata_lfo2"]=0,
   ["strata_lfo2_depth"]=25,
   ["strata_lfo2_depth_mod"]=1,
   ["strata_lfo2_depth_mod_amt"]=0,
   ["strata_lfo2_division"]=13,
   ["strata_lfo2_mode"]=1,
   ["strata_lfo2_offset"]=0,
   ["strata_lfo2_phase"]=0,
   ["strata_lfo2_rate"]=0.25,
   ["strata_lfo2_rate_mod"]=1,
   ["strata_lfo2_rate_mod_amt"]=0,
   ["strata_lfo2_shape"]=1,
   ["strata_lfo3"]=0,
   ["strata_lfo3_depth"]=25,
   ["strata_lfo3_depth_mod"]=1,
   ["strata_lfo3_depth_mod_amt"]=0,
   ["strata_lfo3_division"]=13,
   ["strata_lfo3_mode"]=1,
   ["strata_lfo3_offset"]=0,
   ["strata_lfo3_phase"]=0,
   ["strata_lfo3_rate"]=0.25,
   ["strata_lfo3_rate_mod"]=1,
   ["strata_lfo3_rate_mod_amt"]=0,
   ["strata_lfo3_shape"]=1,
   ["strata_lfo4"]=0,
   ["strata_lfo4_depth"]=25,
   ["strata_lfo4_depth_mod"]=1,
   ["strata_lfo4_depth_mod_amt"]=0,
   ["strata_lfo4_division"]=13,
   ["strata_lfo4_mode"]=1,
   ["strata_lfo4_offset"]=0,
   ["strata_lfo4_phase"]=0,
   ["strata_lfo4_rate"]=0.25,
   ["strata_lfo4_rate_mod"]=1,
   ["strata_lfo4_rate_mod_amt"]=0,
   ["strata_lfo4_shape"]=1,
   ["strata_lfo5"]=0,
   ["strata_lfo5_depth"]=25,
   ["strata_lfo5_depth_mod"]=1,
   ["strata_lfo5_depth_mod_amt"]=0,
   ["strata_lfo5_division"]=13,
   ["strata_lfo5_mode"]=1,
   ["strata_lfo5_offset"]=0,
   ["strata_lfo5_phase"]=0,
   ["strata_lfo5_rate"]=0.25,
   ["strata_lfo5_rate_mod"]=1,
   ["strata_lfo5_rate_mod_amt"]=0,
   ["strata_lfo5_shape"]=1,
   ["strata_lfo6"]=0,
   ["strata_lfo6_depth"]=25,
   ["strata_lfo6_depth_mod"]=1,
   ["strata_lfo6_depth_mod_amt"]=0,
   ["strata_lfo6_division"]=13,
   ["strata_lfo6_mode"]=1,
   ["strata_lfo6_offset"]=0,
   ["strata_lfo6_phase"]=0,
   ["strata_lfo6_rate"]=0.25,
   ["strata_lfo6_rate_mod"]=1,
   ["strata_lfo6_rate_mod_amt"]=0,
   ["strata_lfo6_shape"]=1,
   ["tempo"]=120,
   ["voices"]={48},
},
-- Table: {23}
{
},
-- Table: {24}
{
},
-- Table: {25}
{
},
-- Table: {26}
{
},
-- Table: {27}
{
},
-- Table: {28}
{
},
-- Table: {29}
{
},
-- Table: {30}
{
},
-- Table: {31}
{
},
-- Table: {32}
{
},
-- Table: {33}
{
},
-- Table: {34}
{
},
-- Table: {35}
{
   false,
   false,
   false,
   false,
   false,
   false,
   false,
},
-- Table: {36}
{
   {49},
},
-- Table: {37}
{
   {50},
   [17]={51},
   [18]={52},
},
-- Table: {38}
{
   {53},
   {54},
   {55},
   {56},
   {57},
   {58},
   {59},
},
-- Table: {39}
{
   {60},
   {61},
   {62},
   {63},
},
-- Table: {40}
{
   {64},
   {65},
   {66},
   {67},
   {68},
   {69},
   {70},
},
-- Table: {41}
{
   {71},
   {72},
   {73},
   {74},
   {75},
   {76},
   {77},
},
-- Table: {42}
{
   false,
   false,
   false,
   false,
   false,
   false,
   false,
},
-- Table: {43}
{
   {78},
},
-- Table: {44}
{
   {79},
   [17]={80},
   [18]={81},
},
-- Table: {45}
{
   {82},
   {83},
   {84},
   {85},
   {86},
   {87},
   {88},
},
-- Table: {46}
{
   {89},
   {90},
   {91},
   {92},
},
-- Table: {47}
{
   {93},
   {94},
   {95},
   {96},
   {97},
   {98},
   {99},
},
-- Table: {48}
{
   {100},
   {101},
   {102},
   {103},
   {104},
   {105},
   {106},
},
-- Table: {49}
{
   {107},
},
-- Table: {50}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
},
-- Table: {51}
{
   ["dest"]="v2_main",
   ["source"]="lfo1",
},
-- Table: {52}
{
   ["dest"]="reverb_mix",
   ["source"]="lfo2",
},
-- Table: {53}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {54}
{
   0,
   0,
   9,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {55}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {56}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {57}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {58}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {59}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {60}
{
   0.17622178047895,
   -0.43671682197601,
   0.92178492341191,
   -0.19789250101894,
   0.17247600108385,
   -0.8957390608266,
   0.9497184259817,
   -0.23345071356744,
   0.53885153215379,
   -0.33548184670508,
   0.55430753156543,
   0.22460316494107,
   0.95070204511285,
   0.25720034446567,
   -0.24011442903429,
   -0.93805538862944,
},
-- Table: {61}
{
   0.50765955541283,
   -0.034393905662,
   0.50189359858632,
   -0.48175504337996,
   -0.39294555038214,
   -0.32373060844839,
   -0.20353481732309,
   -0.23623704537749,
   -0.78321134019643,
   0.18071774300188,
   -0.92294945754111,
   0.016902081668377,
   -0.73778861109167,
   0.84398100618273,
   -0.068801026791334,
   0.43843316938728,
},
-- Table: {62}
{
   -0.59273581579328,
   -0.14701610337943,
   -0.75945933163166,
   0.57974018529058,
   -0.042755164206028,
   -0.80974090564996,
   -0.65371052734554,
   -0.50390363112092,
   -0.14522275142372,
   0.90059700421989,
   0.72069953382015,
   -0.19452070631087,
   0.15779734868556,
   -0.51941489521414,
   -0.1325760949403,
   -0.33454309497029,
},
-- Table: {63}
{
   0.44619120005518,
   -0.63068249542266,
   0.18370186164975,
   -0.94675435032696,
   0.045586896128953,
   0.98016704432666,
   -0.18299139570445,
   0.26237555593252,
   0.16088478825986,
   -0.10594085231423,
   -0.7207223623991,
   0.42309617716819,
   -0.2619598461315,
   0.21047661080956,
   -0.13847065251321,
   0.14530433900654,
},
-- Table: {64}
{
},
-- Table: {65}
{
   [3]={108},
},
-- Table: {66}
{
},
-- Table: {67}
{
},
-- Table: {68}
{
},
-- Table: {69}
{
},
-- Table: {70}
{
},
-- Table: {71}
{
   ["active"]=true,
   ["source"]=2,
   ["values"]={109},
},
-- Table: {72}
{
   ["active"]=true,
   ["source"]=4,
   ["values"]={110},
},
-- Table: {73}
{
   ["active"]=false,
   ["source"]=5,
   ["values"]={111},
},
-- Table: {74}
{
   ["active"]=false,
   ["source"]=6,
   ["values"]={112},
},
-- Table: {75}
{
   ["active"]=false,
   ["source"]=10,
   ["values"]={113},
},
-- Table: {76}
{
   ["active"]=false,
   ["source"]=3,
   ["values"]={114},
},
-- Table: {77}
{
   ["active"]=false,
   ["source"]=5,
   ["values"]={115},
},
-- Table: {78}
{
   {116},
},
-- Table: {79}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
},
-- Table: {80}
{
   ["dest"]="v2_main",
   ["source"]="lfo1",
},
-- Table: {81}
{
   ["dest"]="reverb_mix",
   ["source"]="lfo2",
},
-- Table: {82}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {83}
{
   0,
   0,
   9,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {84}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {85}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {86}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {87}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {88}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {89}
{
   0.17622178047895,
   -0.43671682197601,
   0.92178492341191,
   -0.19789250101894,
   0.17247600108385,
   -0.8957390608266,
   0.9497184259817,
   -0.23345071356744,
   0.53885153215379,
   -0.33548184670508,
   0.55430753156543,
   0.22460316494107,
   0.95070204511285,
   0.25720034446567,
   -0.24011442903429,
   -0.93805538862944,
},
-- Table: {90}
{
   0.50765955541283,
   -0.034393905662,
   0.50189359858632,
   -0.48175504337996,
   -0.39294555038214,
   -0.32373060844839,
   -0.20353481732309,
   -0.23623704537749,
   -0.78321134019643,
   0.18071774300188,
   -0.92294945754111,
   0.016902081668377,
   -0.73778861109167,
   0.84398100618273,
   -0.068801026791334,
   0.43843316938728,
},
-- Table: {91}
{
   -0.59273581579328,
   -0.14701610337943,
   -0.75945933163166,
   0.57974018529058,
   -0.042755164206028,
   -0.80974090564996,
   -0.65371052734554,
   -0.50390363112092,
   -0.14522275142372,
   0.90059700421989,
   0.72069953382015,
   -0.19452070631087,
   0.15779734868556,
   -0.51941489521414,
   -0.1325760949403,
   -0.33454309497029,
},
-- Table: {92}
{
   0.44619120005518,
   -0.63068249542266,
   0.18370186164975,
   -0.94675435032696,
   0.045586896128953,
   0.98016704432666,
   -0.18299139570445,
   0.26237555593252,
   0.16088478825986,
   -0.10594085231423,
   -0.7207223623991,
   0.42309617716819,
   -0.2619598461315,
   0.21047661080956,
   -0.13847065251321,
   0.14530433900654,
},
-- Table: {93}
{
},
-- Table: {94}
{
   [3]={117},
},
-- Table: {95}
{
},
-- Table: {96}
{
},
-- Table: {97}
{
},
-- Table: {98}
{
},
-- Table: {99}
{
},
-- Table: {100}
{
   ["active"]=true,
   ["source"]=6,
   ["values"]={118},
},
-- Table: {101}
{
   ["active"]=true,
   ["source"]=7,
   ["values"]={119},
},
-- Table: {102}
{
   ["active"]=false,
   ["source"]=3,
   ["values"]={120},
},
-- Table: {103}
{
   ["active"]=false,
   ["source"]=9,
   ["values"]={121},
},
-- Table: {104}
{
   ["active"]=false,
   ["source"]=7,
   ["values"]={122},
},
-- Table: {105}
{
   ["active"]=false,
   ["source"]=10,
   ["values"]={123},
},
-- Table: {106}
{
   ["active"]=false,
   ["source"]=1,
   ["values"]={124},
},
-- Table: {107}
{
   ["id"]="reverb_mix",
   ["max"]=0.8,
   ["min"]=0.2,
},
-- Table: {108}
{
   ["notes"]={125},
   ["prob"]=40,
   ["ratchet"]=3,
},
-- Table: {109}
{
   ["amp"]=0.3,
   ["attack"]=4.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.97485921299085,
   ["buf_rate"]=1.6872799120611,
   ["buf_scan"]=0.5,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=100.0,
   ["grain_density"]=78,
   ["grain_env"]=4,
   ["grain_mode"]=2,
   ["grain_pitch"]=0.6042609391734,
   ["grain_size"]=0.23,
   ["grain_spread"]=0.33,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod1"]=0.1,
   ["mod2"]=0.15,
   ["mod_amp_amt_1"]=-0.48,
   ["mod_amp_amt_2"]=-0.07,
   ["mod_amp_amt_3"]=-0.79,
   ["mod_freq_amt_1"]=-1.88,
   ["mod_freq_amt_2"]=1.0,
   ["mod_freq_amt_3"]=-0.65,
   ["mod_source_1"]=5,
   ["mod_source_2"]=6,
   ["mod_source_3"]=2,
   ["mod_speed"]=16.4,
   ["mute"]=0,
   ["noise"]=0.5,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=8.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["rq"]=0.1,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {110}
{
   ["amp"]=0.25,
   ["attack"]=5.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.92199050309137,
   ["buf_rate"]=1.9959980747662,
   ["buf_scan"]=0.88,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=80.0,
   ["grain_density"]=43,
   ["grain_env"]=1,
   ["grain_mode"]=2,
   ["grain_pitch"]=0.76221138890833,
   ["grain_size"]=0.2,
   ["grain_spread"]=0.2,
   ["history"]=0,
   ["index"]=2.0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["modFreq"]=0.05,
   ["mod_amp_amt_1"]=-1.62,
   ["mod_amp_amt_2"]=-0.29,
   ["mod_amp_amt_3"]=-0.39,
   ["mod_freq_amt_1"]=-1.31,
   ["mod_freq_amt_2"]=1.8,
   ["mod_freq_amt_3"]=0.32,
   ["mod_source_1"]=3,
   ["mod_source_2"]=1,
   ["mod_source_3"]=6,
   ["mod_speed"]=10.1,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=1.5,
   ["release"]=10.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {111}
{
   ["amp"]=0.3,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.52279344806448,
   ["buf_rate"]=3.9628132081125,
   ["buf_scan"]=-0.37,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["fold"]=1.0,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=60.0,
   ["grain_density"]=59,
   ["grain_env"]=3,
   ["grain_mode"]=1,
   ["grain_pitch"]=0.55324564967304,
   ["grain_size"]=0.23,
   ["grain_spread"]=0.63,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.2,
   ["mod_amp_amt_1"]=-0.52,
   ["mod_amp_amt_2"]=0.29,
   ["mod_amp_amt_3"]=-0.55,
   ["mod_freq_amt_1"]=0.42,
   ["mod_freq_amt_2"]=-1.87,
   ["mod_freq_amt_3"]=0.04,
   ["mod_source_1"]=5,
   ["mod_source_2"]=3,
   ["mod_source_3"]=4,
   ["mod_speed"]=26.3,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=6.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {112}
{
   ["amp"]=0.4,
   ["attack"]=8.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.064864175394177,
   ["buf_rate"]=3.471411909326,
   ["buf_scan"]=1.64,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["drift"]=0.02,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=40.0,
   ["grain_density"]=59,
   ["grain_env"]=1,
   ["grain_mode"]=2,
   ["grain_pitch"]=1.4525856534019,
   ["grain_size"]=0.24,
   ["grain_spread"]=0.4,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=0.47,
   ["mod_amp_amt_2"]=-1.01,
   ["mod_amp_amt_3"]=-0.45,
   ["mod_freq_amt_1"]=1.92,
   ["mod_freq_amt_2"]=0.24,
   ["mod_freq_amt_3"]=-0.91,
   ["mod_source_1"]=4,
   ["mod_source_2"]=0,
   ["mod_source_3"]=3,
   ["mod_speed"]=33.8,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=12.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {113}
{
   ["amp"]=0.3,
   ["attack"]=2.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.025252136867493,
   ["buf_rate"]=1.1999396733008,
   ["buf_scan"]=1.07,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["cutoff"]=2000,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=120.0,
   ["grain_density"]=90,
   ["grain_env"]=2,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.3119354471564,
   ["grain_size"]=0.26,
   ["grain_spread"]=0.54,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=1.16,
   ["mod_amp_amt_2"]=1.42,
   ["mod_amp_amt_3"]=-0.99,
   ["mod_freq_amt_1"]=1.65,
   ["mod_freq_amt_2"]=1.09,
   ["mod_freq_amt_3"]=-0.58,
   ["mod_source_1"]=7,
   ["mod_source_2"]=3,
   ["mod_source_3"]=2,
   ["mod_speed"]=18.7,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=4.0,
   ["res"]=0.8,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
   ["width"]=0.5,
},
-- Table: {114}
{
   ["amp"]=0.35,
   ["attack"]=0.01,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.78151940461248,
   ["buf_rate"]=1.9159795830492,
   ["buf_scan"]=0.83,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["damping"]=0.5,
   ["decay"]=4.0,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["excite"]=0.3,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=200.0,
   ["grain_density"]=28,
   ["grain_env"]=4,
   ["grain_mode"]=2,
   ["grain_pitch"]=1.1401957152411,
   ["grain_size"]=0.34,
   ["grain_spread"]=0.05,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=0.91,
   ["mod_amp_amt_2"]=-0.95,
   ["mod_amp_amt_3"]=0.23,
   ["mod_freq_amt_1"]=-1.97,
   ["mod_freq_amt_2"]=1.63,
   ["mod_freq_amt_3"]=1.52,
   ["mod_source_1"]=5,
   ["mod_source_2"]=3,
   ["mod_source_3"]=6,
   ["mod_speed"]=22.4,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=2.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {115}
{
   ["amp"]=0.25,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["brightness"]=0.5,
   ["buf_pos"]=0.59525992395356,
   ["buf_rate"]=0.7892865720205,
   ["buf_scan"]=1.58,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=300.0,
   ["grain_density"]=22,
   ["grain_env"]=1,
   ["grain_mode"]=2,
   ["grain_pitch"]=1.8077598148957,
   ["grain_size"]=0.26,
   ["grain_spread"]=0.56,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.2,
   ["mod_amp_amt_1"]=1.6,
   ["mod_amp_amt_2"]=1.81,
   ["mod_amp_amt_3"]=0.83,
   ["mod_freq_amt_1"]=1.93,
   ["mod_freq_amt_2"]=-0.96,
   ["mod_freq_amt_3"]=1.77,
   ["mod_source_1"]=4,
   ["mod_source_2"]=1,
   ["mod_source_3"]=7,
   ["mod_speed"]=27.4,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=1.618,
   ["release"]=5.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {116}
{
   ["id"]="reverb_mix",
   ["max"]=0.8,
   ["min"]=0.2,
},
-- Table: {117}
{
   ["notes"]={126},
   ["prob"]=40,
   ["ratchet"]=3,
},
-- Table: {118}
{
   ["amp"]=0.3,
   ["attack"]=4.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.27713945647702,
   ["buf_rate"]=0.98045004624873,
   ["buf_scan"]=1.44,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=100.0,
   ["grain_density"]=45,
   ["grain_env"]=1,
   ["grain_mode"]=1,
   ["grain_pitch"]=2.3368766000494,
   ["grain_size"]=0.29,
   ["grain_spread"]=0.35,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod1"]=0.1,
   ["mod2"]=0.15,
   ["mod_amp_amt_1"]=-0.61,
   ["mod_amp_amt_2"]=0.74,
   ["mod_amp_amt_3"]=-1.52,
   ["mod_freq_amt_1"]=0.9,
   ["mod_freq_amt_2"]=1.71,
   ["mod_freq_amt_3"]=-1.77,
   ["mod_source_1"]=1,
   ["mod_source_2"]=4,
   ["mod_source_3"]=6,
   ["mod_speed"]=11.9,
   ["mute"]=0,
   ["noise"]=0.5,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=8.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["rq"]=0.1,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {119}
{
   ["amp"]=0.25,
   ["attack"]=5.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.058346468489617,
   ["buf_rate"]=1.9127885366324,
   ["buf_scan"]=-0.1,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=80.0,
   ["grain_density"]=23,
   ["grain_env"]=5,
   ["grain_mode"]=2,
   ["grain_pitch"]=2.4383306857198,
   ["grain_size"]=0.24,
   ["grain_spread"]=0.15,
   ["history"]=0,
   ["index"]=2.0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["modFreq"]=0.05,
   ["mod_amp_amt_1"]=-1.62,
   ["mod_amp_amt_2"]=-0.22,
   ["mod_amp_amt_3"]=-0.07,
   ["mod_freq_amt_1"]=-1.39,
   ["mod_freq_amt_2"]=0.4,
   ["mod_freq_amt_3"]=0.92,
   ["mod_source_1"]=1,
   ["mod_source_2"]=0,
   ["mod_source_3"]=0,
   ["mod_speed"]=15.6,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=1.5,
   ["release"]=10.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {120}
{
   ["amp"]=0.3,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.19074117997661,
   ["buf_rate"]=1.7083861990832,
   ["buf_scan"]=1.23,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["fold"]=1.0,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=60.0,
   ["grain_density"]=71,
   ["grain_env"]=3,
   ["grain_mode"]=1,
   ["grain_pitch"]=0.86499510053545,
   ["grain_size"]=0.08,
   ["grain_spread"]=0.8,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.2,
   ["mod_amp_amt_1"]=0.47,
   ["mod_amp_amt_2"]=1.06,
   ["mod_amp_amt_3"]=0.89,
   ["mod_freq_amt_1"]=1.46,
   ["mod_freq_amt_2"]=-1.62,
   ["mod_freq_amt_3"]=-1.03,
   ["mod_source_1"]=5,
   ["mod_source_2"]=1,
   ["mod_source_3"]=7,
   ["mod_speed"]=3.1,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=6.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {121}
{
   ["amp"]=0.4,
   ["attack"]=8.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.20526960352436,
   ["buf_rate"]=2.7047910975525,
   ["buf_scan"]=-1.22,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["drift"]=0.02,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=40.0,
   ["grain_density"]=72,
   ["grain_env"]=2,
   ["grain_mode"]=2,
   ["grain_pitch"]=2.4791247202083,
   ["grain_size"]=0.13,
   ["grain_spread"]=0.46,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=0.08,
   ["mod_amp_amt_2"]=-0.73,
   ["mod_amp_amt_3"]=0.96,
   ["mod_freq_amt_1"]=1.82,
   ["mod_freq_amt_2"]=0.66,
   ["mod_freq_amt_3"]=-0.63,
   ["mod_source_1"]=7,
   ["mod_source_2"]=5,
   ["mod_source_3"]=2,
   ["mod_speed"]=35.9,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=12.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {122}
{
   ["amp"]=0.3,
   ["attack"]=2.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.94127021497115,
   ["buf_rate"]=2.2393809559289,
   ["buf_scan"]=-1.01,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["cutoff"]=2000,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=120.0,
   ["grain_density"]=4,
   ["grain_env"]=4,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.2443413771689,
   ["grain_size"]=0.19,
   ["grain_spread"]=0.19,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=1.72,
   ["mod_amp_amt_2"]=-0.43,
   ["mod_amp_amt_3"]=1.84,
   ["mod_freq_amt_1"]=-1.51,
   ["mod_freq_amt_2"]=1.36,
   ["mod_freq_amt_3"]=0.96,
   ["mod_source_1"]=0,
   ["mod_source_2"]=1,
   ["mod_source_3"]=4,
   ["mod_speed"]=3.4,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=4.0,
   ["res"]=0.8,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
   ["width"]=0.5,
},
-- Table: {123}
{
   ["amp"]=0.35,
   ["attack"]=0.01,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.58007102133706,
   ["buf_rate"]=2.9350301923696,
   ["buf_scan"]=-1.48,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["damping"]=0.5,
   ["decay"]=4.0,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["excite"]=0.3,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=200.0,
   ["grain_density"]=61,
   ["grain_env"]=4,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.2789788441733,
   ["grain_size"]=0.18,
   ["grain_spread"]=0.92,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=-0.27,
   ["mod_amp_amt_2"]=-0.5,
   ["mod_amp_amt_3"]=0.26,
   ["mod_freq_amt_1"]=1.54,
   ["mod_freq_amt_2"]=-0.34,
   ["mod_freq_amt_3"]=-0.18,
   ["mod_source_1"]=2,
   ["mod_source_2"]=4,
   ["mod_source_3"]=6,
   ["mod_speed"]=24.3,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=2.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {124}
{
   ["amp"]=0.25,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["brightness"]=0.71,
   ["buf_pos"]=0.87912564352155,
   ["buf_rate"]=3.0207907976583,
   ["buf_scan"]=-0.68,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=184.74975800093,
   ["grain_density"]=19,
   ["grain_env"]=4,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.0182461105287,
   ["grain_size"]=0.35,
   ["grain_spread"]=0.79,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.32,
   ["mod_amp_amt_1"]=1.4,
   ["mod_amp_amt_2"]=0.34,
   ["mod_amp_amt_3"]=-1.93,
   ["mod_freq_amt_1"]=-0.81,
   ["mod_freq_amt_2"]=0.87,
   ["mod_freq_amt_3"]=0.41,
   ["mod_source_1"]=7,
   ["mod_source_2"]=4,
   ["mod_source_3"]=6,
   ["mod_speed"]=15.6,
   ["mute"]=0,
   ["pan"]=0.84,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=4.442,
   ["release"]=5.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {125}
{
   0,
   7,
},
-- Table: {126}
{
   0,
   7,
},
}]==],
  ["strata-05.pset"] = [==[
-- groundwork
"LEVELS": 9
"REVERB": 11
"rev_eng_input": -9.0
"rev_cut_input": -9.0
"rev_monitor_input": -inf
"rev_tape_input": -inf
"rev_return_level": -9.6432746655329e-16
"rev_pre_delay": 60.0
"rev_lf_fc": 200.0
"rev_low_time": 6.0
"rev_mid_time": 6.0
"rev_hf_damping": 6000.0
"COMPRESSOR": 8
"comp_mix": 1
"comp_ratio": 4.0
"comp_threshold": -18.0
"comp_attack": 5.0
"comp_release": 50.0
"comp_pre_gain": 0.0
"comp_post_gain": 9.0
"SOFTCUT": 3
"cut_input_adc": -9.6432746655329e-16
"cut_input_eng": -9.6432746655329e-16
"cut_input_tape": -inf
"CLOCK": 29
"master_density": 1.0
"tempo": 120
"mutation_enabled": 0
"mutation_rate": 2.0
"mutation_probability": 0.15
"mutation_amount": 0.25
"scene_sequencer_enabled": 0
"scene_transition_time": 2.0
"scene_duration": 16
"scene_sequence_length": 4
"scene_chance_next": 100
"scene_chance_previous": 0
"scene_chance_random": 0
"strata_fx": 16
"filter_type": 1
"filter_freq": 5000.0
"filter_res": 0.5
"filter_mix": 0.0
"delay_time": 0.375
"delay_feedback": 0.4
"delay_mix": 0.0
"reverb_mix": 0.3
"reverb_size": 0.8
"reverb_damp": 0.5
"drift_amount": 0.01
"delay_bypass": 0
"reverb_bypass": 0
"delay_sync": 0
"delay_division": 7
"delay_pingpong": 0.0
"strata_lfo_1": 12
"strata_lfo1": 1
"strata_lfo1_shape": 1
"strata_lfo1_mode": 1
"strata_lfo1_rate": 0.25
"strata_lfo1_division": 13
"strata_lfo1_depth": 40
"strata_lfo1_offset": 0
"strata_lfo1_phase": 0
"strata_lfo1_rate_mod": 1
"strata_lfo1_rate_mod_amt": 0
"strata_lfo1_depth_mod": 1
"strata_lfo1_depth_mod_amt": 0
"strata_lfo_2": 12
"strata_lfo2": 0
"strata_lfo2_shape": 1
"strata_lfo2_mode": 1
"strata_lfo2_rate": 0.25
"strata_lfo2_division": 13
"strata_lfo2_depth": 25
"strata_lfo2_offset": 0
"strata_lfo2_phase": 0
"strata_lfo2_rate_mod": 1
"strata_lfo2_rate_mod_amt": 0
"strata_lfo2_depth_mod": 1
"strata_lfo2_depth_mod_amt": 0
"strata_lfo_3": 12
"strata_lfo3": 0
"strata_lfo3_shape": 1
"strata_lfo3_mode": 1
"strata_lfo3_rate": 0.25
"strata_lfo3_division": 13
"strata_lfo3_depth": 25
"strata_lfo3_offset": 0
"strata_lfo3_phase": 0
"strata_lfo3_rate_mod": 1
"strata_lfo3_rate_mod_amt": 0
"strata_lfo3_depth_mod": 1
"strata_lfo3_depth_mod_amt": 0
"strata_lfo_4": 12
"strata_lfo4": 0
"strata_lfo4_shape": 1
"strata_lfo4_mode": 1
"strata_lfo4_rate": 0.25
"strata_lfo4_division": 13
"strata_lfo4_depth": 25
"strata_lfo4_offset": 0
"strata_lfo4_phase": 0
"strata_lfo4_rate_mod": 1
"strata_lfo4_rate_mod_amt": 0
"strata_lfo4_depth_mod": 1
"strata_lfo4_depth_mod_amt": 0
"strata_lfo_5": 12
"strata_lfo5": 0
"strata_lfo5_shape": 1
"strata_lfo5_mode": 1
"strata_lfo5_rate": 0.25
"strata_lfo5_division": 13
"strata_lfo5_depth": 25
"strata_lfo5_offset": 0
"strata_lfo5_phase": 0
"strata_lfo5_rate_mod": 1
"strata_lfo5_rate_mod_amt": 0
"strata_lfo5_depth_mod": 1
"strata_lfo5_depth_mod_amt": 0
"strata_lfo_6": 12
"strata_lfo6": 0
"strata_lfo6_shape": 1
"strata_lfo6_mode": 1
"strata_lfo6_rate": 0.25
"strata_lfo6_division": 13
"strata_lfo6_depth": 25
"strata_lfo6_offset": 0
"strata_lfo6_phase": 0
"strata_lfo6_rate_mod": 1
"strata_lfo6_rate_mod_amt": 0
"strata_lfo6_depth_mod": 1
"strata_lfo6_depth_mod_amt": 0
"strata_macros": 16
"macro_1": 0
"macro_2": 0
"macro_3": 0
"macro_4": 0
"macro_5": 0
"macro_6": 0
"macro_7": 0
"macro_8": 0
"macro_9": 0
"macro_10": 0
"macro_11": 0
"macro_12": 0
"macro_13": 0
"macro_14": 0
"macro_15": 0
"macro_16": 0
"strata_morph": 6
"morph": 0
"morph_a": 1
"morph_b": 2
"morph_c": 3
"morph_d": 4
"morph_y": 0
"strata_scatter": 8
"scatter": 0
"scatter_depth": 10
"scatter_rate": 0.1
"scatter_pitch": 1
"scatter_pos": 1
"scatter_size": 0
"scatter_cutoff": 0
"scatter_amp": 0
"strata_matrix": 32
"matrix_1_depth": 40
"matrix_1": 1
"matrix_2_depth": 0
"matrix_2": 1
"matrix_3_depth": 0
"matrix_3": 1
"matrix_4_depth": 0
"matrix_4": 1
"matrix_5_depth": 0
"matrix_5": 1
"matrix_6_depth": 0
"matrix_6": 1
"matrix_7_depth": 0
"matrix_7": 1
"matrix_8_depth": 0
"matrix_8": 1
"matrix_9_depth": 0
"matrix_9": 1
"matrix_10_depth": 0
"matrix_10": 1
"matrix_11_depth": 0
"matrix_11": 1
"matrix_12_depth": 0
"matrix_12": 1
"matrix_13_depth": 0
"matrix_13": 1
"matrix_14_depth": 0
"matrix_14": 1
"matrix_15_depth": 0
"matrix_15": 1
"matrix_16_depth": 0
"matrix_16": 1
"strata_input": 1
"input_follow_gain": 4.0
"strata_gestures": 8
"gesture_1_quantize": 1
"gesture_2_quantize": 1
"gesture_3_quantize": 1
"gesture_4_quantize": 1
"strata_rseq": 16
"rseq1_length": 8
"rseq1_drift": 0
"rseq1_clock": 6
"rseq2_length": 8
"rseq2_drift": 0
"rseq2_clock": 6
"rseq3_length": 8
"rseq3_drift": 0
"rseq3_clock": 6
"rseq4_length": 8
"rseq4_drift": 0
"rseq4_clock": 6
"strata_out_midi": 74
"v1_out_port": 0
"v1_out_channel": 1
"v1_out_mode": 1
"v1_out_members": 15
"v2_out_port": 0
"v2_out_channel": 2
"v2_out_mode": 1
"v2_out_members": 15
"v3_out_port": 0
"v3_out_channel": 3
"v3_out_mode": 1
"v3_out_members": 15
"v4_out_port": 0
"v4_out_channel": 4
"v4_out_mode": 1
"v4_out_members": 15
"v5_out_port": 0
"v5_out_channel": 5
"v5_out_mode": 1
"v5_out_members": 15
"v6_out_port": 0
"v6_out_channel": 6
"v6_out_mode": 1
"v6_out_members": 15
"v7_out_port": 0
"v7_out_channel": 7
"v7_out_mode": 1
"v7_out_members": 15
"midi_out_bend_range": 48
"cc_out1_source_key": off
"cc_out1_port": 1
"cc_out1_channel": 1
"cc_out1_number": 1
"cc_out2_source_key": off
"cc_out2_port": 1
"cc_out2_channel": 1
"cc_out2_number": 2
"cc_out3_source_key": off
"cc_out3_port": 1
"cc_out3_channel": 1
"cc_out3_number": 3
"cc_out4_source_key": off
"cc_out4_port": 1
"cc_out4_channel": 1
"cc_out4_number": 4
"cc_out5_source_key": off
"cc_out5_port": 1
"cc_out5_channel": 1
"cc_out5_number": 5
"cc_out6_source_key": off
"cc_out6_port": 1
"cc_out6_channel": 1
"cc_out6_number": 6
"cc_out7_source_key": off
"cc_out7_port": 1
"cc_out7_channel": 1
"cc_out7_number": 7
"cc_out8_source_key": off
"cc_out8_port": 1
"cc_out8_channel": 1
"cc_out8_number": 8
"midi_pc_in": 0
"midi_pc_channel": 1
"midi_pc_out": 0
"midi_pc_out_port": 1
"midi_pc_out_channel": 1
"strata_crow": 24
"crow_in1_mode": 1
"crow_in1_range": 1
"crow_in1_action": 1
"crow_in1_voice": 0
"crow_in2_mode": 1
"crow_in2_range": 1
"crow_in2_action": 1
"crow_in2_voice": 0
"crow_out1_source_key": off
"crow_out1_range": 1
"crow_out1_div": 5
"crow_out2_source_key": off
"crow_out2_range": 1
"crow_out2_div": 5
"crow_out3_source_key": off
"crow_out3_range": 1
"crow_out3_div": 5
"crow_out4_source_key": off
"crow_out4_range": 1
"crow_out4_div": 5
"strata_out_ii": 39
"v1_out_jf": 0
"v2_out_jf": 0
"v3_out_jf": 0
"v4_out_jf": 0
"v5_out_jf": 0
"v6_out_jf": 0
"v7_out_jf": 0
"jf_level": 5.0
"v1_out_wsyn": 0
"v2_out_wsyn": 0
"v3_out_wsyn": 0
"v4_out_wsyn": 0
"v5_out_wsyn": 0
"v6_out_wsyn": 0
"v7_out_wsyn": 0
"wsyn_level": 5.0
"v1_out_er301": 0
"v2_out_er301": 0
"v3_out_er301": 0
"v4_out_er301": 0
"v5_out_er301": 0
"v6_out_er301": 0
"v7_out_er301": 0
"v1_out_txo": 0
"v1_out_txo_cv": 1
"v2_out_txo": 0
"v2_out_txo_cv": 1
"v3_out_txo": 0
"v3_out_txo_cv": 1
"v4_out_txo": 0
"v4_out_txo_cv": 1
"v5_out_txo": 0
"v5_out_txo_cv": 1
"v6_out_txo": 0
"v6_out_txo_cv": 1
"v7_out_txo": 0
"v7_out_txo_cv": 1
"txo_attack": 10
"txo_decay": 500
"strata_out_nb": 14
"v1_out_nb_key": none
"v2_out_nb_key": none
"v3_out_nb_key": none
"v4_out_nb_key": none
"v5_out_nb_key": none
"v6_out_nb_key": none
"v7_out_nb_key": none
"strata_tape": 7
"tapeloop": 0
"tapeloop_rec": 1
"tapeloop_length": 4.0
"tapeloop_rate": 1.0
"tapeloop_feedback": 0.5
"tapeloop_wear": 0.2
"tapeloop_level": 0.7
"strata_seq": 11
"seq_chain": 0
"seq_chain_from": 1
"seq_chain_scenes": 2
"seq_chain_bars": 4
"seq_chain_next": 100
"seq_chain_previous": 0
"seq_chain_random": 0
"quantize_actions": 1
"seq_follow_transport": 1
"strata_buffers": 34
"record_duration": 8.0
"record_level": 1.0
"buf1_file": @AUDIO@
"buf2_file": @AUDIO@
"buf3_file": @AUDIO@
"buf4_file": @AUDIO@
"buf5_file": @AUDIO@
"buf6_file": @AUDIO@
"buf7_file": @AUDIO@
"buf8_file": @AUDIO@
"strata_record": 6
"record_source": 1
"record_feedback": 0
"record_loop": 1
"record_threshold": 1
"record_sync": 1
"record_beats": 16
"strata_positions": 1
"scrub_friction": 100
"strata_midi": 6
"midi_device": 1
"midi_channel_mode": 1
"midi_note_off": 1
"mpe_lower_members": 15
"mpe_upper_members": 0
"mpe_bend_range": 48
"strata_zones": 21
"v1_zone": 2
"v1_zone_low": 0
"v1_zone_high": 127
"v2_zone": 3
"v2_zone_low": 0
"v2_zone_high": 127
"v3_zone": 1
"v3_zone_low": 0
"v3_zone_high": 127
"v4_zone": 1
"v4_zone_low": 0
"v4_zone_high": 127
"v5_zone": 1
"v5_zone_low": 0
"v5_zone_high": 127
"v6_zone": 1
"v6_zone_low": 0
"v6_zone_high": 127
"v7_zone": 1
"v7_zone_low": 0
"v7_zone_high": 127
"scale": 1
"root": 1
"v1_quantize": 0
"v1_freq": 100.0
"v1_rq": 0.1
"v1_noise": 0.5
"v1_mod1": 0.1
"v1_mod2": 0.15
"v1_amp": 0.3
"v1_pan": 0.0
"v1_source": 6
"v1_buf_pos": 0.27713945647702
"v1_buf_rate": 0.98045004624873
"v1_buf_scan": 1.44
"v1_grain_size": 0.29
"v1_grain_density": 45
"v1_grain_pitch": 2.3368766000494
"v1_grain_spread": 0.35
"v1_grain_env": 1
"v1_grain_mode": 1
"v1_mod_source_1": 1
"v1_mod_amp_amt_1": -0.61
"v1_mod_freq_amt_1": 0.9
"v1_mod_source_2": 4
"v1_mod_amp_amt_2": 0.74
"v1_mod_freq_amt_2": 1.71
"v1_mod_source_3": 6
"v1_mod_amp_amt_3": -1.52
"v1_mod_freq_amt_3": -1.77
"v1_mod_speed": 11.9
"v1_history": 0
"v1_freeze": 0
"v1_freeze_mode": 1
"v1_loop_start": 0
"v1_loop_length": 1
"v1_reverse": 0
"v1_pitch_jitter": 0.0
"v1_pan_jitter": 0.0
"v1_size_jitter": 0.0
"v1_intervals": 1
"v1_interval_prob": 100
"v1_custom_interval_1": -12
"v1_custom_interval_2": 0
"v1_custom_interval_3": 7
"v1_custom_interval_4": 12
"v1_custom_interval_5": 19
"v1_filter_type": 1
"v1_filter_freq": 5000.0
"v1_filter_res": 0.5
"v1_filter_mix": 0.0
"v1_delay_send": 1.0
"v1_reverb_send": 1.0
"v1_mute": 0
"v1_solo": 0
"v1_bookmark_1": 0
"v1_bookmark_2": 0.25
"v1_bookmark_3": 0.5
"v1_bookmark_4": 0.75
"v1_scan_mode": 1
"v1_follow": 1
"v1_env_attack": 0.005
"v1_env_decay": 0.2
"v1_env_sustain": 0
"v1_env_release": 0.2
"v1_env_curve": -4.0
"v1_env_loop": 1
"v1_note_cap": 8
"v1_attack": 4.0
"v1_release": 8.0
"v1_press_target": 2
"v1_press_depth": 100
"v1_slide_target": 4
"v1_slide_depth": 50
"v1_slices": 1
"v1_seq_length": 16
"v1_seq_division": 3
"v1_seq_gate": 1
"v1_seq_gate_length": 0.5
"v1_seq_gate_release": 0.1
"v1_seq_swing": 50
"v1_seq_direction": 1
"v1_seq_misstep": 0
"v2_quantize": 0
"v2_freq": 80.0
"v2_ratio": 1.5
"v2_index": 2.0
"v2_modFreq": 0.05
"v2_amp": 0.25
"v2_pan": 0.0
"v2_source": 7
"v2_buf_pos": 0.058346468489617
"v2_buf_rate": 1.9127885366324
"v2_buf_scan": -0.1
"v2_grain_size": 0.24
"v2_grain_density": 23
"v2_grain_pitch": 2.4383306857198
"v2_grain_spread": 0.15
"v2_grain_env": 5
"v2_grain_mode": 2
"v2_mod_source_1": 1
"v2_mod_amp_amt_1": -1.62
"v2_mod_freq_amt_1": -1.39
"v2_mod_source_2": 0
"v2_mod_amp_amt_2": -0.22
"v2_mod_freq_amt_2": 0.4
"v2_mod_source_3": 0
"v2_mod_amp_amt_3": -0.07
"v2_mod_freq_amt_3": 0.92
"v2_mod_speed": 15.6
"v2_history": 0
"v2_freeze": 0
"v2_freeze_mode": 1
"v2_loop_start": 0
"v2_loop_length": 1
"v2_reverse": 0
"v2_pitch_jitter": 0.0
"v2_pan_jitter": 0.0
"v2_size_jitter": 0.0
"v2_intervals": 1
"v2_interval_prob": 100
"v2_custom_interval_1": -12
"v2_custom_interval_2": 0
"v2_custom_interval_3": 7
"v2_custom_interval_4": 12
"v2_custom_interval_5": 19
"v2_filter_type": 1
"v2_filter_freq": 5000.0
"v2_filter_res": 0.5
"v2_filter_mix": 0.0
"v2_delay_send": 1.0
"v2_reverb_send": 1.0
"v2_mute": 0
"v2_solo": 0
"v2_bookmark_1": 0
"v2_bookmark_2": 0.25
"v2_bookmark_3": 0.5
"v2_bookmark_4": 0.75
"v2_scan_mode": 1
"v2_follow": 1
"v2_env_attack": 0.005
"v2_env_decay": 0.2
"v2_env_sustain": 0
"v2_env_release": 0.2
"v2_env_curve": -4.0
"v2_env_loop": 1
"v2_note_cap": 8
"v2_attack": 5.0
"v2_release": 10.0
"v2_press_target": 2
"v2_press_depth": 100
"v2_slide_target": 4
"v2_slide_depth": 50
"v2_slices": 1
"v2_seq_length": 16
"v2_seq_division": 3
"v2_seq_gate": 1
"v2_seq_gate_length": 0.5
"v2_seq_gate_release": 0.1
"v2_seq_swing": 50
"v2_seq_direction": 1
"v2_seq_misstep": 0
"v3_quantize": 0
"v3_freq": 60.0
"v3_fold": 1.0
"v3_mod": 0.2
"v3_amp": 0.3
"v3_pan": 0.0
"v3_source": 3
"v3_buf_pos": 0.19074117997661
"v3_buf_rate": 1.7083861990832
"v3_buf_scan": 1.23
"v3_grain_size": 0.08
"v3_grain_density": 71
"v3_grain_pitch": 0.86499510053545
"v3_grain_spread": 0.8
"v3_grain_env": 3
"v3_grain_mode": 1
"v3_mod_source_1": 5
"v3_mod_amp_amt_1": 0.47
"v3_mod_freq_amt_1": 1.46
"v3_mod_source_2": 1
"v3_mod_amp_amt_2": 1.06
"v3_mod_freq_amt_2": -1.62
"v3_mod_source_3": 7
"v3_mod_amp_amt_3": 0.89
"v3_mod_freq_amt_3": -1.03
"v3_mod_speed": 3.1
"v3_history": 0
"v3_freeze": 0
"v3_freeze_mode": 1
"v3_loop_start": 0
"v3_loop_length": 1
"v3_reverse": 0
"v3_pitch_jitter": 0.0
"v3_pan_jitter": 0.0
"v3_size_jitter": 0.0
"v3_intervals": 1
"v3_interval_prob": 100
"v3_custom_interval_1": -12
"v3_custom_interval_2": 0
"v3_custom_interval_3": 7
"v3_custom_interval_4": 12
"v3_custom_interval_5": 19
"v3_filter_type": 1
"v3_filter_freq": 5000.0
"v3_filter_res": 0.5
"v3_filter_mix": 0.0
"v3_delay_send": 1.0
"v3_reverb_send": 1.0
"v3_mute": 0
"v3_solo": 0
"v3_bookmark_1": 0
"v3_bookmark_2": 0.25
"v3_bookmark_3": 0.5
"v3_bookmark_4": 0.75
"v3_scan_mode": 1
"v3_follow": 1
"v3_env_attack": 0.005
"v3_env_decay": 0.2
"v3_env_sustain": 0
"v3_env_release": 0.2
"v3_env_curve": -4.0
"v3_env_loop": 1
"v3_note_cap": 8
"v3_attack": 3.0
"v3_release": 6.0
"v3_press_target": 2
"v3_press_depth": 100
"v3_slide_target": 4
"v3_slide_depth": 50
"v3_slices": 1
"v3_seq_length": 16
"v3_seq_division": 3
"v3_seq_gate": 1
"v3_seq_gate_length": 0.5
"v3_seq_gate_release": 0.1
"v3_seq_swing": 50
"v3_seq_direction": 1
"v3_seq_misstep": 0
"v4_quantize": 0
"v4_freq": 40.0
"v4_drift": 0.02
"v4_amp": 0.4
"v4_source": 9
"v4_buf_pos": 0.20526960352436
"v4_buf_rate": 2.7047910975525
"v4_buf_scan": -1.22
"v4_grain_size": 0.13
"v4_grain_density": 72
"v4_grain_pitch": 2.4791247202083
"v4_grain_spread": 0.46
"v4_grain_env": 2
"v4_grain_mode": 2
"v4_mod_source_1": 7
"v4_mod_amp_amt_1": 0.08
"v4_mod_freq_amt_1": 1.82
"v4_mod_source_2": 5
"v4_mod_amp_amt_2": -0.73
"v4_mod_freq_amt_2": 0.66
"v4_mod_source_3": 2
"v4_mod_amp_amt_3": 0.96
"v4_mod_freq_amt_3": -0.63
"v4_mod_speed": 35.9
"v4_history": 0
"v4_freeze": 0
"v4_freeze_mode": 1
"v4_loop_start": 0
"v4_loop_length": 1
"v4_reverse": 0
"v4_pitch_jitter": 0.0
"v4_pan_jitter": 0.0
"v4_size_jitter": 0.0
"v4_intervals": 1
"v4_interval_prob": 100
"v4_custom_interval_1": -12
"v4_custom_interval_2": 0
"v4_custom_interval_3": 7
"v4_custom_interval_4": 12
"v4_custom_interval_5": 19
"v4_filter_type": 1
"v4_filter_freq": 5000.0
"v4_filter_res": 0.5
"v4_filter_mix": 0.0
"v4_delay_send": 1.0
"v4_reverb_send": 1.0
"v4_mute": 0
"v4_solo": 0
"v4_bookmark_1": 0
"v4_bookmark_2": 0.25
"v4_bookmark_3": 0.5
"v4_bookmark_4": 0.75
"v4_scan_mode": 1
"v4_follow": 1
"v4_env_attack": 0.005
"v4_env_decay": 0.2
"v4_env_sustain": 0
"v4_env_release": 0.2
"v4_env_curve": -4.0
"v4_env_loop": 1
"v4_note_cap": 8
"v4_attack": 8.0
"v4_release": 12.0
"v4_press_target": 2
"v4_press_depth": 100
"v4_slide_target": 4
"v4_slide_depth": 50
"v4_slices": 1
"v4_seq_length": 16
"v4_seq_division": 3
"v4_seq_gate": 1
"v4_seq_gate_length": 0.5
"v4_seq_gate_release": 0.1
"v4_seq_swing": 50
"v4_seq_direction": 1
"v4_seq_misstep": 0
"v5_quantize": 0
"v5_freq": 120.0
"v5_width": 0.5
"v5_cutoff": 2000
"v5_res": 0.8
"v5_amp": 0.3
"v5_pan": 0.0
"v5_source": 7
"v5_buf_pos": 0.94127021497115
"v5_buf_rate": 2.2393809559289
"v5_buf_scan": -1.01
"v5_grain_size": 0.19
"v5_grain_density": 4
"v5_grain_pitch": 1.2443413771689
"v5_grain_spread": 0.19
"v5_grain_env": 4
"v5_grain_mode": 1
"v5_mod_source_1": 0
"v5_mod_amp_amt_1": 1.72
"v5_mod_freq_amt_1": -1.51
"v5_mod_source_2": 1
"v5_mod_amp_amt_2": -0.43
"v5_mod_freq_amt_2": 1.36
"v5_mod_source_3": 4
"v5_mod_amp_amt_3": 1.84
"v5_mod_freq_amt_3": 0.96
"v5_mod_speed": 3.4
"v5_history": 0
"v5_freeze": 0
"v5_freeze_mode": 1
"v5_loop_start": 0
"v5_loop_length": 1
"v5_reverse": 0
"v5_pitch_jitter": 0.0
"v5_pan_jitter": 0.0
"v5_size_jitter": 0.0
"v5_intervals": 1
"v5_interval_prob": 100
"v5_custom_interval_1": -12
"v5_custom_interval_2": 0
"v5_custom_interval_3": 7
"v5_custom_interval_4": 12
"v5_custom_interval_5": 19
"v5_filter_type": 1
"v5_filter_freq": 5000.0
"v5_filter_res": 0.5
"v5_filter_mix": 0.0
"v5_delay_send": 1.0
"v5_reverb_send": 1.0
"v5_mute": 0
"v5_solo": 0
"v5_bookmark_1": 0
"v5_bookmark_2": 0.25
"v5_bookmark_3": 0.5
"v5_bookmark_4": 0.75
"v5_scan_mode": 1
"v5_follow": 1
"v5_env_attack": 0.005
"v5_env_decay": 0.2
"v5_env_sustain": 0
"v5_env_release": 0.2
"v5_env_curve": -4.0
"v5_env_loop": 1
"v5_note_cap": 8
"v5_attack": 2.0
"v5_release": 4.0
"v5_press_target": 2
"v5_press_depth": 100
"v5_slide_target": 4
"v5_slide_depth": 50
"v5_slices": 1
"v5_seq_length": 16
"v5_seq_division": 3
"v5_seq_gate": 1
"v5_seq_gate_length": 0.5
"v5_seq_gate_release": 0.1
"v5_seq_swing": 50
"v5_seq_direction": 1
"v5_seq_misstep": 0
"v6_quantize": 0
"v6_freq": 200.0
"v6_decay": 4.0
"v6_damping": 0.5
"v6_excite": 0.3
"v6_amp": 0.35
"v6_pan": 0.0
"v6_source": 10
"v6_buf_pos": 0.58007102133706
"v6_buf_rate": 2.9350301923696
"v6_buf_scan": -1.48
"v6_grain_size": 0.18
"v6_grain_density": 61
"v6_grain_pitch": 1.2789788441733
"v6_grain_spread": 0.92
"v6_grain_env": 4
"v6_grain_mode": 1
"v6_mod_source_1": 2
"v6_mod_amp_amt_1": -0.27
"v6_mod_freq_amt_1": 1.54
"v6_mod_source_2": 4
"v6_mod_amp_amt_2": -0.5
"v6_mod_freq_amt_2": -0.34
"v6_mod_source_3": 6
"v6_mod_amp_amt_3": 0.26
"v6_mod_freq_amt_3": -0.18
"v6_mod_speed": 24.3
"v6_history": 0
"v6_freeze": 0
"v6_freeze_mode": 1
"v6_loop_start": 0
"v6_loop_length": 1
"v6_reverse": 0
"v6_pitch_jitter": 0.0
"v6_pan_jitter": 0.0
"v6_size_jitter": 0.0
"v6_intervals": 1
"v6_interval_prob": 100
"v6_custom_interval_1": -12
"v6_custom_interval_2": 0
"v6_custom_interval_3": 7
"v6_custom_interval_4": 12
"v6_custom_interval_5": 19
"v6_filter_type": 1
"v6_filter_freq": 5000.0
"v6_filter_res": 0.5
"v6_filter_mix": 0.0
"v6_delay_send": 1.0
"v6_reverb_send": 1.0
"v6_mute": 0
"v6_solo": 0
"v6_bookmark_1": 0
"v6_bookmark_2": 0.25
"v6_bookmark_3": 0.5
"v6_bookmark_4": 0.75
"v6_scan_mode": 1
"v6_follow": 1
"v6_env_attack": 0.005
"v6_env_decay": 0.2
"v6_env_sustain": 0
"v6_env_release": 0.2
"v6_env_curve": -4.0
"v6_env_loop": 1
"v6_note_cap": 8
"v6_attack": 0.01
"v6_release": 2.0
"v6_press_target": 2
"v6_press_depth": 100
"v6_slide_target": 4
"v6_slide_depth": 50
"v6_slices": 1
"v6_seq_length": 16
"v6_seq_division": 3
"v6_seq_gate": 1
"v6_seq_gate_length": 0.5
"v6_seq_gate_release": 0.1
"v6_seq_swing": 50
"v6_seq_direction": 1
"v6_seq_misstep": 0
"v7_quantize": 0
"v7_freq": 184.74975800093
"v7_ratio": 4.442
"v7_mod": 0.32
"v7_brightness": 0.71
"v7_amp": 0.25
"v7_pan": 0.84
"v7_source": 1
"v7_buf_pos": 0.87912564352155
"v7_buf_rate": 3.0207907976583
"v7_buf_scan": -0.68
"v7_grain_size": 0.35
"v7_grain_density": 19
"v7_grain_pitch": 1.0182461105287
"v7_grain_spread": 0.79
"v7_grain_env": 4
"v7_grain_mode": 1
"v7_mod_source_1": 7
"v7_mod_amp_amt_1": 1.4
"v7_mod_freq_amt_1": -0.81
"v7_mod_source_2": 4
"v7_mod_amp_amt_2": 0.34
"v7_mod_freq_amt_2": 0.87
"v7_mod_source_3": 6
"v7_mod_amp_amt_3": -1.93
"v7_mod_freq_amt_3": 0.41
"v7_mod_speed": 15.6
"v7_history": 0
"v7_freeze": 0
"v7_freeze_mode": 1
"v7_loop_start": 0
"v7_loop_length": 1
"v7_reverse": 0
"v7_pitch_jitter": 0.0
"v7_pan_jitter": 0.0
"v7_size_jitter": 0.0
"v7_intervals": 1
"v7_interval_prob": 100
"v7_custom_interval_1": -12
"v7_custom_interval_2": 0
"v7_custom_interval_3": 7
"v7_custom_interval_4": 12
"v7_custom_interval_5": 19
"v7_filter_type": 1
"v7_filter_freq": 5000.0
"v7_filter_res": 0.5
"v7_filter_mix": 0.0
"v7_delay_send": 1.0
"v7_reverb_send": 1.0
"v7_mute": 0
"v7_solo": 0
"v7_bookmark_1": 0
"v7_bookmark_2": 0.25
"v7_bookmark_3": 0.5
"v7_bookmark_4": 0.75
"v7_scan_mode": 1
"v7_follow": 1
"v7_env_attack": 0.005
"v7_env_decay": 0.2
"v7_env_sustain": 0
"v7_env_release": 0.2
"v7_env_curve": -4.0
"v7_env_loop": 1
"v7_note_cap": 8
"v7_attack": 3.0
"v7_release": 5.0
"v7_press_target": 2
"v7_press_depth": 100
"v7_slide_target": 4
"v7_slide_depth": 50
"v7_slices": 1
"v7_seq_length": 16
"v7_seq_division": 3
"v7_seq_gate": 1
"v7_seq_gate_length": 0.5
"v7_seq_gate_release": 0.1
"v7_seq_swing": 50
"v7_seq_direction": 1
"v7_seq_misstep": 0
]==],
  ["strata-05.macros.data"] = [==[
return {
-- Table: {1}
{
   ["macros"]={2},
   ["version"]=1,
},
-- Table: {2}
{
   {3},
},
-- Table: {3}
{
   {4},
},
-- Table: {4}
{
   ["id"]="reverb_mix",
   ["max"]=0.8,
   ["min"]=0.2,
},
}]==],
  ["strata-05.matrix.data"] = [==[
return {
-- Table: {1}
{
   ["matrix"]={2},
   ["version"]=2,
},
-- Table: {2}
{
   {3},
   [17]={4},
   [18]={5},
},
-- Table: {3}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
},
-- Table: {4}
{
   ["dest"]="v2_main",
   ["source"]="lfo1",
},
-- Table: {5}
{
   ["dest"]="reverb_mix",
   ["source"]="lfo2",
},
}]==],
  ["strata-05.gestures.data"] = [==[
return {
-- Table: {1}
{
   ["recorders"]={2},
   ["version"]=1,
},
-- Table: {2}
{
   {3},
   {4},
   {5},
   {6},
},
-- Table: {3}
{
   ["quantize"]="free",
},
-- Table: {4}
{
   ["quantize"]="free",
},
-- Table: {5}
{
   ["quantize"]="free",
},
-- Table: {6}
{
   ["quantize"]="free",
},
}]==],
  ["strata-05.sequences.data"] = [==[
return {
-- Table: {1}
{
   ["sequences"]={2},
   ["version"]=1,
},
-- Table: {2}
{
   {3},
   {4},
   {5},
   {6},
},
-- Table: {3}
{
   0.17622178047895,
   -0.43671682197601,
   0.92178492341191,
   -0.19789250101894,
   0.17247600108385,
   -0.8957390608266,
   0.9497184259817,
   -0.23345071356744,
   0.53885153215379,
   -0.33548184670508,
   0.55430753156543,
   0.22460316494107,
   0.95070204511285,
   0.25720034446567,
   -0.24011442903429,
   -0.93805538862944,
},
-- Table: {4}
{
   0.50765955541283,
   -0.034393905662,
   0.50189359858632,
   -0.48175504337996,
   -0.39294555038214,
   -0.32373060844839,
   -0.20353481732309,
   -0.23623704537749,
   -0.78321134019643,
   0.18071774300188,
   -0.92294945754111,
   0.016902081668377,
   -0.73778861109167,
   0.84398100618273,
   -0.068801026791334,
   0.43843316938728,
},
-- Table: {5}
{
   -0.59273581579328,
   -0.14701610337943,
   -0.75945933163166,
   0.57974018529058,
   -0.042755164206028,
   -0.80974090564996,
   -0.65371052734554,
   -0.50390363112092,
   -0.14522275142372,
   0.90059700421989,
   0.72069953382015,
   -0.19452070631087,
   0.15779734868556,
   -0.51941489521414,
   -0.1325760949403,
   -0.33454309497029,
},
-- Table: {6}
{
   0.44619120005518,
   -0.63068249542266,
   0.18370186164975,
   -0.94675435032696,
   0.045586896128953,
   0.98016704432666,
   -0.18299139570445,
   0.26237555593252,
   0.16088478825986,
   -0.10594085231423,
   -0.7207223623991,
   0.42309617716819,
   -0.2619598461315,
   0.21047661080956,
   -0.13847065251321,
   0.14530433900654,
},
}]==],
  ["strata-05.scenes.data"] = [==[
return {
-- Table: {1}
{
   ["scenes"]={2},
   ["version"]=9,
},
-- Table: {2}
{
   {3},
   {4},
   {5},
   {6},
   {7},
   {8},
   {9},
   {10},
   {11},
   {12},
   {13},
   {14},
   {15},
   {16},
   {17},
   {18},
},
-- Table: {3}
{
   ["data"]={19},
   ["name"]="",
   ["populated"]=true,
},
-- Table: {4}
{
   ["data"]={20},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {5}
{
   ["data"]={21},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {6}
{
   ["data"]={22},
   ["name"]="four",
   ["populated"]=true,
},
-- Table: {7}
{
   ["data"]={23},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {8}
{
   ["data"]={24},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {9}
{
   ["data"]={25},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {10}
{
   ["data"]={26},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {11}
{
   ["data"]={27},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {12}
{
   ["data"]={28},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {13}
{
   ["data"]={29},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {14}
{
   ["data"]={30},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {15}
{
   ["data"]={31},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {16}
{
   ["data"]={32},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {17}
{
   ["data"]={33},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {18}
{
   ["data"]={34},
   ["name"]="",
   ["populated"]=false,
},
-- Table: {19}
{
   ["delay_division"]=7,
   ["delay_feedback"]=0.4,
   ["delay_mix"]=0.0,
   ["delay_pingpong"]=0.0,
   ["delay_sync"]=0,
   ["delay_time"]=0.375,
   ["drift_amount"]=0.01,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["gesture_1_play"]=0,
   ["gesture_2_play"]=0,
   ["gesture_3_play"]=0,
   ["gesture_4_play"]=0,
   ["locked"]={35},
   ["macro_1"]=0,
   ["macro_10"]=0,
   ["macro_11"]=0,
   ["macro_12"]=0,
   ["macro_13"]=0,
   ["macro_14"]=0,
   ["macro_15"]=0,
   ["macro_16"]=0,
   ["macro_2"]=0,
   ["macro_3"]=0,
   ["macro_4"]=0,
   ["macro_5"]=0,
   ["macro_6"]=0,
   ["macro_7"]=0,
   ["macro_8"]=0,
   ["macro_9"]=0,
   ["macros"]={36},
   ["master_density"]=1.0,
   ["matrix"]={37},
   ["matrix_1"]=1,
   ["matrix_10"]=1,
   ["matrix_10_depth"]=0,
   ["matrix_11"]=1,
   ["matrix_11_depth"]=0,
   ["matrix_12"]=1,
   ["matrix_12_depth"]=0,
   ["matrix_13"]=1,
   ["matrix_13_depth"]=0,
   ["matrix_14"]=1,
   ["matrix_14_depth"]=0,
   ["matrix_15"]=1,
   ["matrix_15_depth"]=0,
   ["matrix_16"]=1,
   ["matrix_16_depth"]=0,
   ["matrix_1_depth"]=40,
   ["matrix_2"]=1,
   ["matrix_2_depth"]=0,
   ["matrix_3"]=1,
   ["matrix_3_depth"]=0,
   ["matrix_4"]=1,
   ["matrix_4_depth"]=0,
   ["matrix_5"]=1,
   ["matrix_5_depth"]=0,
   ["matrix_6"]=1,
   ["matrix_6_depth"]=0,
   ["matrix_7"]=1,
   ["matrix_7_depth"]=0,
   ["matrix_8"]=1,
   ["matrix_8_depth"]=0,
   ["matrix_9"]=1,
   ["matrix_9_depth"]=0,
   ["mutation_amount"]=0.25,
   ["mutation_enabled"]=0,
   ["mutation_probability"]=0.15,
   ["mutation_rate"]=2.0,
   ["patterns"]={38},
   ["reverb_damp"]=0.5,
   ["reverb_mix"]=0.3,
   ["reverb_size"]=0.8,
   ["root"]=1,
   ["scale"]=1,
   ["scatter"]=0,
   ["scatter_amp"]=0,
   ["scatter_cutoff"]=0,
   ["scatter_depth"]=10,
   ["scatter_pitch"]=1,
   ["scatter_pos"]=1,
   ["scatter_rate"]=0.1,
   ["scatter_size"]=0,
   ["sequences"]={39},
   ["steps"]={40},
   ["strata_lfo1"]=1,
   ["strata_lfo1_depth"]=40,
   ["strata_lfo1_depth_mod"]=1,
   ["strata_lfo1_depth_mod_amt"]=0,
   ["strata_lfo1_division"]=13,
   ["strata_lfo1_mode"]=1,
   ["strata_lfo1_offset"]=0,
   ["strata_lfo1_phase"]=0,
   ["strata_lfo1_rate"]=0.25,
   ["strata_lfo1_rate_mod"]=1,
   ["strata_lfo1_rate_mod_amt"]=0,
   ["strata_lfo1_shape"]=1,
   ["strata_lfo2"]=0,
   ["strata_lfo2_depth"]=25,
   ["strata_lfo2_depth_mod"]=1,
   ["strata_lfo2_depth_mod_amt"]=0,
   ["strata_lfo2_division"]=13,
   ["strata_lfo2_mode"]=1,
   ["strata_lfo2_offset"]=0,
   ["strata_lfo2_phase"]=0,
   ["strata_lfo2_rate"]=0.25,
   ["strata_lfo2_rate_mod"]=1,
   ["strata_lfo2_rate_mod_amt"]=0,
   ["strata_lfo2_shape"]=1,
   ["strata_lfo3"]=0,
   ["strata_lfo3_depth"]=25,
   ["strata_lfo3_depth_mod"]=1,
   ["strata_lfo3_depth_mod_amt"]=0,
   ["strata_lfo3_division"]=13,
   ["strata_lfo3_mode"]=1,
   ["strata_lfo3_offset"]=0,
   ["strata_lfo3_phase"]=0,
   ["strata_lfo3_rate"]=0.25,
   ["strata_lfo3_rate_mod"]=1,
   ["strata_lfo3_rate_mod_amt"]=0,
   ["strata_lfo3_shape"]=1,
   ["strata_lfo4"]=0,
   ["strata_lfo4_depth"]=25,
   ["strata_lfo4_depth_mod"]=1,
   ["strata_lfo4_depth_mod_amt"]=0,
   ["strata_lfo4_division"]=13,
   ["strata_lfo4_mode"]=1,
   ["strata_lfo4_offset"]=0,
   ["strata_lfo4_phase"]=0,
   ["strata_lfo4_rate"]=0.25,
   ["strata_lfo4_rate_mod"]=1,
   ["strata_lfo4_rate_mod_amt"]=0,
   ["strata_lfo4_shape"]=1,
   ["strata_lfo5"]=0,
   ["strata_lfo5_depth"]=25,
   ["strata_lfo5_depth_mod"]=1,
   ["strata_lfo5_depth_mod_amt"]=0,
   ["strata_lfo5_division"]=13,
   ["strata_lfo5_mode"]=1,
   ["strata_lfo5_offset"]=0,
   ["strata_lfo5_phase"]=0,
   ["strata_lfo5_rate"]=0.25,
   ["strata_lfo5_rate_mod"]=1,
   ["strata_lfo5_rate_mod_amt"]=0,
   ["strata_lfo5_shape"]=1,
   ["strata_lfo6"]=0,
   ["strata_lfo6_depth"]=25,
   ["strata_lfo6_depth_mod"]=1,
   ["strata_lfo6_depth_mod_amt"]=0,
   ["strata_lfo6_division"]=13,
   ["strata_lfo6_mode"]=1,
   ["strata_lfo6_offset"]=0,
   ["strata_lfo6_phase"]=0,
   ["strata_lfo6_rate"]=0.25,
   ["strata_lfo6_rate_mod"]=1,
   ["strata_lfo6_rate_mod_amt"]=0,
   ["strata_lfo6_shape"]=1,
   ["tempo"]=120,
   ["voices"]={41},
},
-- Table: {20}
{
},
-- Table: {21}
{
},
-- Table: {22}
{
   ["delay_division"]=7,
   ["delay_feedback"]=0.4,
   ["delay_mix"]=0.0,
   ["delay_pingpong"]=0.0,
   ["delay_sync"]=0,
   ["delay_time"]=0.375,
   ["drift_amount"]=0.01,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["gesture_1_play"]=0,
   ["gesture_2_play"]=0,
   ["gesture_3_play"]=0,
   ["gesture_4_play"]=0,
   ["locked"]={42},
   ["macro_1"]=0,
   ["macro_10"]=0,
   ["macro_11"]=0,
   ["macro_12"]=0,
   ["macro_13"]=0,
   ["macro_14"]=0,
   ["macro_15"]=0,
   ["macro_16"]=0,
   ["macro_2"]=0,
   ["macro_3"]=0,
   ["macro_4"]=0,
   ["macro_5"]=0,
   ["macro_6"]=0,
   ["macro_7"]=0,
   ["macro_8"]=0,
   ["macro_9"]=0,
   ["macros"]={43},
   ["master_density"]=1.0,
   ["matrix"]={44},
   ["matrix_1"]=1,
   ["matrix_10"]=1,
   ["matrix_10_depth"]=0,
   ["matrix_11"]=1,
   ["matrix_11_depth"]=0,
   ["matrix_12"]=1,
   ["matrix_12_depth"]=0,
   ["matrix_13"]=1,
   ["matrix_13_depth"]=0,
   ["matrix_14"]=1,
   ["matrix_14_depth"]=0,
   ["matrix_15"]=1,
   ["matrix_15_depth"]=0,
   ["matrix_16"]=1,
   ["matrix_16_depth"]=0,
   ["matrix_1_depth"]=40,
   ["matrix_2"]=1,
   ["matrix_2_depth"]=0,
   ["matrix_3"]=1,
   ["matrix_3_depth"]=0,
   ["matrix_4"]=1,
   ["matrix_4_depth"]=0,
   ["matrix_5"]=1,
   ["matrix_5_depth"]=0,
   ["matrix_6"]=1,
   ["matrix_6_depth"]=0,
   ["matrix_7"]=1,
   ["matrix_7_depth"]=0,
   ["matrix_8"]=1,
   ["matrix_8_depth"]=0,
   ["matrix_9"]=1,
   ["matrix_9_depth"]=0,
   ["mutation_amount"]=0.25,
   ["mutation_enabled"]=0,
   ["mutation_probability"]=0.15,
   ["mutation_rate"]=2.0,
   ["patterns"]={45},
   ["reverb_damp"]=0.5,
   ["reverb_mix"]=0.3,
   ["reverb_size"]=0.8,
   ["root"]=1,
   ["scale"]=1,
   ["scatter"]=0,
   ["scatter_amp"]=0,
   ["scatter_cutoff"]=0,
   ["scatter_depth"]=10,
   ["scatter_pitch"]=1,
   ["scatter_pos"]=1,
   ["scatter_rate"]=0.1,
   ["scatter_size"]=0,
   ["sequences"]={46},
   ["steps"]={47},
   ["strata_lfo1"]=1,
   ["strata_lfo1_depth"]=40,
   ["strata_lfo1_depth_mod"]=1,
   ["strata_lfo1_depth_mod_amt"]=0,
   ["strata_lfo1_division"]=13,
   ["strata_lfo1_mode"]=1,
   ["strata_lfo1_offset"]=0,
   ["strata_lfo1_phase"]=0,
   ["strata_lfo1_rate"]=0.25,
   ["strata_lfo1_rate_mod"]=1,
   ["strata_lfo1_rate_mod_amt"]=0,
   ["strata_lfo1_shape"]=1,
   ["strata_lfo2"]=0,
   ["strata_lfo2_depth"]=25,
   ["strata_lfo2_depth_mod"]=1,
   ["strata_lfo2_depth_mod_amt"]=0,
   ["strata_lfo2_division"]=13,
   ["strata_lfo2_mode"]=1,
   ["strata_lfo2_offset"]=0,
   ["strata_lfo2_phase"]=0,
   ["strata_lfo2_rate"]=0.25,
   ["strata_lfo2_rate_mod"]=1,
   ["strata_lfo2_rate_mod_amt"]=0,
   ["strata_lfo2_shape"]=1,
   ["strata_lfo3"]=0,
   ["strata_lfo3_depth"]=25,
   ["strata_lfo3_depth_mod"]=1,
   ["strata_lfo3_depth_mod_amt"]=0,
   ["strata_lfo3_division"]=13,
   ["strata_lfo3_mode"]=1,
   ["strata_lfo3_offset"]=0,
   ["strata_lfo3_phase"]=0,
   ["strata_lfo3_rate"]=0.25,
   ["strata_lfo3_rate_mod"]=1,
   ["strata_lfo3_rate_mod_amt"]=0,
   ["strata_lfo3_shape"]=1,
   ["strata_lfo4"]=0,
   ["strata_lfo4_depth"]=25,
   ["strata_lfo4_depth_mod"]=1,
   ["strata_lfo4_depth_mod_amt"]=0,
   ["strata_lfo4_division"]=13,
   ["strata_lfo4_mode"]=1,
   ["strata_lfo4_offset"]=0,
   ["strata_lfo4_phase"]=0,
   ["strata_lfo4_rate"]=0.25,
   ["strata_lfo4_rate_mod"]=1,
   ["strata_lfo4_rate_mod_amt"]=0,
   ["strata_lfo4_shape"]=1,
   ["strata_lfo5"]=0,
   ["strata_lfo5_depth"]=25,
   ["strata_lfo5_depth_mod"]=1,
   ["strata_lfo5_depth_mod_amt"]=0,
   ["strata_lfo5_division"]=13,
   ["strata_lfo5_mode"]=1,
   ["strata_lfo5_offset"]=0,
   ["strata_lfo5_phase"]=0,
   ["strata_lfo5_rate"]=0.25,
   ["strata_lfo5_rate_mod"]=1,
   ["strata_lfo5_rate_mod_amt"]=0,
   ["strata_lfo5_shape"]=1,
   ["strata_lfo6"]=0,
   ["strata_lfo6_depth"]=25,
   ["strata_lfo6_depth_mod"]=1,
   ["strata_lfo6_depth_mod_amt"]=0,
   ["strata_lfo6_division"]=13,
   ["strata_lfo6_mode"]=1,
   ["strata_lfo6_offset"]=0,
   ["strata_lfo6_phase"]=0,
   ["strata_lfo6_rate"]=0.25,
   ["strata_lfo6_rate_mod"]=1,
   ["strata_lfo6_rate_mod_amt"]=0,
   ["strata_lfo6_shape"]=1,
   ["tempo"]=120,
   ["voices"]={48},
},
-- Table: {23}
{
},
-- Table: {24}
{
},
-- Table: {25}
{
},
-- Table: {26}
{
},
-- Table: {27}
{
},
-- Table: {28}
{
},
-- Table: {29}
{
},
-- Table: {30}
{
},
-- Table: {31}
{
},
-- Table: {32}
{
},
-- Table: {33}
{
},
-- Table: {34}
{
},
-- Table: {35}
{
   false,
   false,
   false,
   false,
   false,
   false,
   false,
},
-- Table: {36}
{
   {49},
},
-- Table: {37}
{
   {50},
   [17]={51},
   [18]={52},
},
-- Table: {38}
{
   {53},
   {54},
   {55},
   {56},
   {57},
   {58},
   {59},
},
-- Table: {39}
{
   {60},
   {61},
   {62},
   {63},
},
-- Table: {40}
{
   {64},
   {65},
   {66},
   {67},
   {68},
   {69},
   {70},
},
-- Table: {41}
{
   {71},
   {72},
   {73},
   {74},
   {75},
   {76},
   {77},
},
-- Table: {42}
{
   false,
   false,
   false,
   false,
   false,
   false,
   false,
},
-- Table: {43}
{
   {78},
},
-- Table: {44}
{
   {79},
   [17]={80},
   [18]={81},
},
-- Table: {45}
{
   {82},
   {83},
   {84},
   {85},
   {86},
   {87},
   {88},
},
-- Table: {46}
{
   {89},
   {90},
   {91},
   {92},
},
-- Table: {47}
{
   {93},
   {94},
   {95},
   {96},
   {97},
   {98},
   {99},
},
-- Table: {48}
{
   {100},
   {101},
   {102},
   {103},
   {104},
   {105},
   {106},
},
-- Table: {49}
{
   {107},
},
-- Table: {50}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
},
-- Table: {51}
{
   ["dest"]="v2_main",
   ["source"]="lfo1",
},
-- Table: {52}
{
   ["dest"]="reverb_mix",
   ["source"]="lfo2",
},
-- Table: {53}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {54}
{
   0,
   0,
   9,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {55}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {56}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {57}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {58}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {59}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {60}
{
   0.17622178047895,
   -0.43671682197601,
   0.92178492341191,
   -0.19789250101894,
   0.17247600108385,
   -0.8957390608266,
   0.9497184259817,
   -0.23345071356744,
   0.53885153215379,
   -0.33548184670508,
   0.55430753156543,
   0.22460316494107,
   0.95070204511285,
   0.25720034446567,
   -0.24011442903429,
   -0.93805538862944,
},
-- Table: {61}
{
   0.50765955541283,
   -0.034393905662,
   0.50189359858632,
   -0.48175504337996,
   -0.39294555038214,
   -0.32373060844839,
   -0.20353481732309,
   -0.23623704537749,
   -0.78321134019643,
   0.18071774300188,
   -0.92294945754111,
   0.016902081668377,
   -0.73778861109167,
   0.84398100618273,
   -0.068801026791334,
   0.43843316938728,
},
-- Table: {62}
{
   -0.59273581579328,
   -0.14701610337943,
   -0.75945933163166,
   0.57974018529058,
   -0.042755164206028,
   -0.80974090564996,
   -0.65371052734554,
   -0.50390363112092,
   -0.14522275142372,
   0.90059700421989,
   0.72069953382015,
   -0.19452070631087,
   0.15779734868556,
   -0.51941489521414,
   -0.1325760949403,
   -0.33454309497029,
},
-- Table: {63}
{
   0.44619120005518,
   -0.63068249542266,
   0.18370186164975,
   -0.94675435032696,
   0.045586896128953,
   0.98016704432666,
   -0.18299139570445,
   0.26237555593252,
   0.16088478825986,
   -0.10594085231423,
   -0.7207223623991,
   0.42309617716819,
   -0.2619598461315,
   0.21047661080956,
   -0.13847065251321,
   0.14530433900654,
},
-- Table: {64}
{
},
-- Table: {65}
{
   [3]={108},
},
-- Table: {66}
{
},
-- Table: {67}
{
},
-- Table: {68}
{
},
-- Table: {69}
{
},
-- Table: {70}
{
},
-- Table: {71}
{
   ["active"]=true,
   ["source"]=2,
   ["values"]={109},
},
-- Table: {72}
{
   ["active"]=true,
   ["source"]=4,
   ["values"]={110},
},
-- Table: {73}
{
   ["active"]=false,
   ["source"]=5,
   ["values"]={111},
},
-- Table: {74}
{
   ["active"]=false,
   ["source"]=6,
   ["values"]={112},
},
-- Table: {75}
{
   ["active"]=false,
   ["source"]=10,
   ["values"]={113},
},
-- Table: {76}
{
   ["active"]=false,
   ["source"]=3,
   ["values"]={114},
},
-- Table: {77}
{
   ["active"]=false,
   ["source"]=5,
   ["values"]={115},
},
-- Table: {78}
{
   {116},
},
-- Table: {79}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
},
-- Table: {80}
{
   ["dest"]="v2_main",
   ["source"]="lfo1",
},
-- Table: {81}
{
   ["dest"]="reverb_mix",
   ["source"]="lfo2",
},
-- Table: {82}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {83}
{
   0,
   0,
   9,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {84}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {85}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {86}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {87}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {88}
{
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
   0,
},
-- Table: {89}
{
   0.17622178047895,
   -0.43671682197601,
   0.92178492341191,
   -0.19789250101894,
   0.17247600108385,
   -0.8957390608266,
   0.9497184259817,
   -0.23345071356744,
   0.53885153215379,
   -0.33548184670508,
   0.55430753156543,
   0.22460316494107,
   0.95070204511285,
   0.25720034446567,
   -0.24011442903429,
   -0.93805538862944,
},
-- Table: {90}
{
   0.50765955541283,
   -0.034393905662,
   0.50189359858632,
   -0.48175504337996,
   -0.39294555038214,
   -0.32373060844839,
   -0.20353481732309,
   -0.23623704537749,
   -0.78321134019643,
   0.18071774300188,
   -0.92294945754111,
   0.016902081668377,
   -0.73778861109167,
   0.84398100618273,
   -0.068801026791334,
   0.43843316938728,
},
-- Table: {91}
{
   -0.59273581579328,
   -0.14701610337943,
   -0.75945933163166,
   0.57974018529058,
   -0.042755164206028,
   -0.80974090564996,
   -0.65371052734554,
   -0.50390363112092,
   -0.14522275142372,
   0.90059700421989,
   0.72069953382015,
   -0.19452070631087,
   0.15779734868556,
   -0.51941489521414,
   -0.1325760949403,
   -0.33454309497029,
},
-- Table: {92}
{
   0.44619120005518,
   -0.63068249542266,
   0.18370186164975,
   -0.94675435032696,
   0.045586896128953,
   0.98016704432666,
   -0.18299139570445,
   0.26237555593252,
   0.16088478825986,
   -0.10594085231423,
   -0.7207223623991,
   0.42309617716819,
   -0.2619598461315,
   0.21047661080956,
   -0.13847065251321,
   0.14530433900654,
},
-- Table: {93}
{
},
-- Table: {94}
{
   [3]={117},
},
-- Table: {95}
{
},
-- Table: {96}
{
},
-- Table: {97}
{
},
-- Table: {98}
{
},
-- Table: {99}
{
},
-- Table: {100}
{
   ["active"]=true,
   ["source"]=6,
   ["values"]={118},
},
-- Table: {101}
{
   ["active"]=true,
   ["source"]=7,
   ["values"]={119},
},
-- Table: {102}
{
   ["active"]=false,
   ["source"]=3,
   ["values"]={120},
},
-- Table: {103}
{
   ["active"]=false,
   ["source"]=9,
   ["values"]={121},
},
-- Table: {104}
{
   ["active"]=false,
   ["source"]=7,
   ["values"]={122},
},
-- Table: {105}
{
   ["active"]=false,
   ["source"]=10,
   ["values"]={123},
},
-- Table: {106}
{
   ["active"]=false,
   ["source"]=1,
   ["values"]={124},
},
-- Table: {107}
{
   ["id"]="reverb_mix",
   ["max"]=0.8,
   ["min"]=0.2,
},
-- Table: {108}
{
   ["notes"]={125},
   ["prob"]=40,
   ["ratchet"]=3,
},
-- Table: {109}
{
   ["amp"]=0.3,
   ["attack"]=4.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.97485921299085,
   ["buf_rate"]=1.6872799120611,
   ["buf_scan"]=0.5,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=100.0,
   ["grain_density"]=78,
   ["grain_env"]=4,
   ["grain_mode"]=2,
   ["grain_pitch"]=0.6042609391734,
   ["grain_size"]=0.23,
   ["grain_spread"]=0.33,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod1"]=0.1,
   ["mod2"]=0.15,
   ["mod_amp_amt_1"]=-0.48,
   ["mod_amp_amt_2"]=-0.07,
   ["mod_amp_amt_3"]=-0.79,
   ["mod_freq_amt_1"]=-1.88,
   ["mod_freq_amt_2"]=1.0,
   ["mod_freq_amt_3"]=-0.65,
   ["mod_source_1"]=5,
   ["mod_source_2"]=6,
   ["mod_source_3"]=2,
   ["mod_speed"]=16.4,
   ["mute"]=0,
   ["noise"]=0.5,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=8.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["rq"]=0.1,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {110}
{
   ["amp"]=0.25,
   ["attack"]=5.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.92199050309137,
   ["buf_rate"]=1.9959980747662,
   ["buf_scan"]=0.88,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=80.0,
   ["grain_density"]=43,
   ["grain_env"]=1,
   ["grain_mode"]=2,
   ["grain_pitch"]=0.76221138890833,
   ["grain_size"]=0.2,
   ["grain_spread"]=0.2,
   ["history"]=0,
   ["index"]=2.0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["modFreq"]=0.05,
   ["mod_amp_amt_1"]=-1.62,
   ["mod_amp_amt_2"]=-0.29,
   ["mod_amp_amt_3"]=-0.39,
   ["mod_freq_amt_1"]=-1.31,
   ["mod_freq_amt_2"]=1.8,
   ["mod_freq_amt_3"]=0.32,
   ["mod_source_1"]=3,
   ["mod_source_2"]=1,
   ["mod_source_3"]=6,
   ["mod_speed"]=10.1,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=1.5,
   ["release"]=10.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {111}
{
   ["amp"]=0.3,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.52279344806448,
   ["buf_rate"]=3.9628132081125,
   ["buf_scan"]=-0.37,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["fold"]=1.0,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=60.0,
   ["grain_density"]=59,
   ["grain_env"]=3,
   ["grain_mode"]=1,
   ["grain_pitch"]=0.55324564967304,
   ["grain_size"]=0.23,
   ["grain_spread"]=0.63,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.2,
   ["mod_amp_amt_1"]=-0.52,
   ["mod_amp_amt_2"]=0.29,
   ["mod_amp_amt_3"]=-0.55,
   ["mod_freq_amt_1"]=0.42,
   ["mod_freq_amt_2"]=-1.87,
   ["mod_freq_amt_3"]=0.04,
   ["mod_source_1"]=5,
   ["mod_source_2"]=3,
   ["mod_source_3"]=4,
   ["mod_speed"]=26.3,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=6.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {112}
{
   ["amp"]=0.4,
   ["attack"]=8.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.064864175394177,
   ["buf_rate"]=3.471411909326,
   ["buf_scan"]=1.64,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["drift"]=0.02,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=40.0,
   ["grain_density"]=59,
   ["grain_env"]=1,
   ["grain_mode"]=2,
   ["grain_pitch"]=1.4525856534019,
   ["grain_size"]=0.24,
   ["grain_spread"]=0.4,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=0.47,
   ["mod_amp_amt_2"]=-1.01,
   ["mod_amp_amt_3"]=-0.45,
   ["mod_freq_amt_1"]=1.92,
   ["mod_freq_amt_2"]=0.24,
   ["mod_freq_amt_3"]=-0.91,
   ["mod_source_1"]=4,
   ["mod_source_2"]=0,
   ["mod_source_3"]=3,
   ["mod_speed"]=33.8,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=12.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {113}
{
   ["amp"]=0.3,
   ["attack"]=2.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.025252136867493,
   ["buf_rate"]=1.1999396733008,
   ["buf_scan"]=1.07,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["cutoff"]=2000,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=120.0,
   ["grain_density"]=90,
   ["grain_env"]=2,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.3119354471564,
   ["grain_size"]=0.26,
   ["grain_spread"]=0.54,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=1.16,
   ["mod_amp_amt_2"]=1.42,
   ["mod_amp_amt_3"]=-0.99,
   ["mod_freq_amt_1"]=1.65,
   ["mod_freq_amt_2"]=1.09,
   ["mod_freq_amt_3"]=-0.58,
   ["mod_source_1"]=7,
   ["mod_source_2"]=3,
   ["mod_source_3"]=2,
   ["mod_speed"]=18.7,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=4.0,
   ["res"]=0.8,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
   ["width"]=0.5,
},
-- Table: {114}
{
   ["amp"]=0.35,
   ["attack"]=0.01,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.78151940461248,
   ["buf_rate"]=1.9159795830492,
   ["buf_scan"]=0.83,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["damping"]=0.5,
   ["decay"]=4.0,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["excite"]=0.3,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=200.0,
   ["grain_density"]=28,
   ["grain_env"]=4,
   ["grain_mode"]=2,
   ["grain_pitch"]=1.1401957152411,
   ["grain_size"]=0.34,
   ["grain_spread"]=0.05,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=0.91,
   ["mod_amp_amt_2"]=-0.95,
   ["mod_amp_amt_3"]=0.23,
   ["mod_freq_amt_1"]=-1.97,
   ["mod_freq_amt_2"]=1.63,
   ["mod_freq_amt_3"]=1.52,
   ["mod_source_1"]=5,
   ["mod_source_2"]=3,
   ["mod_source_3"]=6,
   ["mod_speed"]=22.4,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=2.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {115}
{
   ["amp"]=0.25,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["brightness"]=0.5,
   ["buf_pos"]=0.59525992395356,
   ["buf_rate"]=0.7892865720205,
   ["buf_scan"]=1.58,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=300.0,
   ["grain_density"]=22,
   ["grain_env"]=1,
   ["grain_mode"]=2,
   ["grain_pitch"]=1.8077598148957,
   ["grain_size"]=0.26,
   ["grain_spread"]=0.56,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.2,
   ["mod_amp_amt_1"]=1.6,
   ["mod_amp_amt_2"]=1.81,
   ["mod_amp_amt_3"]=0.83,
   ["mod_freq_amt_1"]=1.93,
   ["mod_freq_amt_2"]=-0.96,
   ["mod_freq_amt_3"]=1.77,
   ["mod_source_1"]=4,
   ["mod_source_2"]=1,
   ["mod_source_3"]=7,
   ["mod_speed"]=27.4,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=1.618,
   ["release"]=5.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {116}
{
   ["id"]="reverb_mix",
   ["max"]=0.8,
   ["min"]=0.2,
},
-- Table: {117}
{
   ["notes"]={126},
   ["prob"]=40,
   ["ratchet"]=3,
},
-- Table: {118}
{
   ["amp"]=0.3,
   ["attack"]=4.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.27713945647702,
   ["buf_rate"]=0.98045004624873,
   ["buf_scan"]=1.44,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=100.0,
   ["grain_density"]=45,
   ["grain_env"]=1,
   ["grain_mode"]=1,
   ["grain_pitch"]=2.3368766000494,
   ["grain_size"]=0.29,
   ["grain_spread"]=0.35,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod1"]=0.1,
   ["mod2"]=0.15,
   ["mod_amp_amt_1"]=-0.61,
   ["mod_amp_amt_2"]=0.74,
   ["mod_amp_amt_3"]=-1.52,
   ["mod_freq_amt_1"]=0.9,
   ["mod_freq_amt_2"]=1.71,
   ["mod_freq_amt_3"]=-1.77,
   ["mod_source_1"]=1,
   ["mod_source_2"]=4,
   ["mod_source_3"]=6,
   ["mod_speed"]=11.9,
   ["mute"]=0,
   ["noise"]=0.5,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=8.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["rq"]=0.1,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {119}
{
   ["amp"]=0.25,
   ["attack"]=5.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.058346468489617,
   ["buf_rate"]=1.9127885366324,
   ["buf_scan"]=-0.1,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=80.0,
   ["grain_density"]=23,
   ["grain_env"]=5,
   ["grain_mode"]=2,
   ["grain_pitch"]=2.4383306857198,
   ["grain_size"]=0.24,
   ["grain_spread"]=0.15,
   ["history"]=0,
   ["index"]=2.0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["modFreq"]=0.05,
   ["mod_amp_amt_1"]=-1.62,
   ["mod_amp_amt_2"]=-0.22,
   ["mod_amp_amt_3"]=-0.07,
   ["mod_freq_amt_1"]=-1.39,
   ["mod_freq_amt_2"]=0.4,
   ["mod_freq_amt_3"]=0.92,
   ["mod_source_1"]=1,
   ["mod_source_2"]=0,
   ["mod_source_3"]=0,
   ["mod_speed"]=15.6,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=1.5,
   ["release"]=10.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {120}
{
   ["amp"]=0.3,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.19074117997661,
   ["buf_rate"]=1.7083861990832,
   ["buf_scan"]=1.23,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["fold"]=1.0,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=60.0,
   ["grain_density"]=71,
   ["grain_env"]=3,
   ["grain_mode"]=1,
   ["grain_pitch"]=0.86499510053545,
   ["grain_size"]=0.08,
   ["grain_spread"]=0.8,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.2,
   ["mod_amp_amt_1"]=0.47,
   ["mod_amp_amt_2"]=1.06,
   ["mod_amp_amt_3"]=0.89,
   ["mod_freq_amt_1"]=1.46,
   ["mod_freq_amt_2"]=-1.62,
   ["mod_freq_amt_3"]=-1.03,
   ["mod_source_1"]=5,
   ["mod_source_2"]=1,
   ["mod_source_3"]=7,
   ["mod_speed"]=3.1,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=6.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {121}
{
   ["amp"]=0.4,
   ["attack"]=8.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.20526960352436,
   ["buf_rate"]=2.7047910975525,
   ["buf_scan"]=-1.22,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["drift"]=0.02,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=40.0,
   ["grain_density"]=72,
   ["grain_env"]=2,
   ["grain_mode"]=2,
   ["grain_pitch"]=2.4791247202083,
   ["grain_size"]=0.13,
   ["grain_spread"]=0.46,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=0.08,
   ["mod_amp_amt_2"]=-0.73,
   ["mod_amp_amt_3"]=0.96,
   ["mod_freq_amt_1"]=1.82,
   ["mod_freq_amt_2"]=0.66,
   ["mod_freq_amt_3"]=-0.63,
   ["mod_source_1"]=7,
   ["mod_source_2"]=5,
   ["mod_source_3"]=2,
   ["mod_speed"]=35.9,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=12.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {122}
{
   ["amp"]=0.3,
   ["attack"]=2.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.94127021497115,
   ["buf_rate"]=2.2393809559289,
   ["buf_scan"]=-1.01,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["cutoff"]=2000,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=120.0,
   ["grain_density"]=4,
   ["grain_env"]=4,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.2443413771689,
   ["grain_size"]=0.19,
   ["grain_spread"]=0.19,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=1.72,
   ["mod_amp_amt_2"]=-0.43,
   ["mod_amp_amt_3"]=1.84,
   ["mod_freq_amt_1"]=-1.51,
   ["mod_freq_amt_2"]=1.36,
   ["mod_freq_amt_3"]=0.96,
   ["mod_source_1"]=0,
   ["mod_source_2"]=1,
   ["mod_source_3"]=4,
   ["mod_speed"]=3.4,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=4.0,
   ["res"]=0.8,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
   ["width"]=0.5,
},
-- Table: {123}
{
   ["amp"]=0.35,
   ["attack"]=0.01,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["buf_pos"]=0.58007102133706,
   ["buf_rate"]=2.9350301923696,
   ["buf_scan"]=-1.48,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["damping"]=0.5,
   ["decay"]=4.0,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["excite"]=0.3,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=200.0,
   ["grain_density"]=61,
   ["grain_env"]=4,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.2789788441733,
   ["grain_size"]=0.18,
   ["grain_spread"]=0.92,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod_amp_amt_1"]=-0.27,
   ["mod_amp_amt_2"]=-0.5,
   ["mod_amp_amt_3"]=0.26,
   ["mod_freq_amt_1"]=1.54,
   ["mod_freq_amt_2"]=-0.34,
   ["mod_freq_amt_3"]=-0.18,
   ["mod_source_1"]=2,
   ["mod_source_2"]=4,
   ["mod_source_3"]=6,
   ["mod_speed"]=24.3,
   ["mute"]=0,
   ["pan"]=0.0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=2.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {124}
{
   ["amp"]=0.25,
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["brightness"]=0.71,
   ["buf_pos"]=0.87912564352155,
   ["buf_rate"]=3.0207907976583,
   ["buf_scan"]=-0.68,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["env_attack"]=0.005,
   ["env_curve"]=-4.0,
   ["env_decay"]=0.2,
   ["env_loop"]=1,
   ["env_release"]=0.2,
   ["env_sustain"]=0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["follow"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["freq"]=184.74975800093,
   ["grain_density"]=19,
   ["grain_env"]=4,
   ["grain_mode"]=1,
   ["grain_pitch"]=1.0182461105287,
   ["grain_size"]=0.35,
   ["grain_spread"]=0.79,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mod"]=0.32,
   ["mod_amp_amt_1"]=1.4,
   ["mod_amp_amt_2"]=0.34,
   ["mod_amp_amt_3"]=-1.93,
   ["mod_freq_amt_1"]=-0.81,
   ["mod_freq_amt_2"]=0.87,
   ["mod_freq_amt_3"]=0.41,
   ["mod_source_1"]=7,
   ["mod_source_2"]=4,
   ["mod_source_3"]=6,
   ["mod_speed"]=15.6,
   ["mute"]=0,
   ["pan"]=0.84,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["ratio"]=4.442,
   ["release"]=5.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["scan_mode"]=1,
   ["seq_direction"]=1,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_misstep"]=0,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slices"]=1,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {125}
{
   0,
   7,
},
-- Table: {126}
{
   0,
   7,
},
}]==],
}
