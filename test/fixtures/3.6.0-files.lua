-- test/fixtures/3.6.0-files.lua
-- A scenes file, a PSET and the PSET's three side files as Strata 3.6.0
-- writes them, for test/unit/system_37_test.lua (a 3.6 session's files
-- loading in 3.7 with their values as saved; the 3.7 plan's Task 3a, its
-- review's Important 2). Each value is the file's text, byte for byte, but
-- for one substitution: the PSET's buf<n>_file lines held the recording's
-- temporary audio folder, written here as @AUDIO@ (the test puts its own
-- audio folder there).
--
-- How it was recorded (2026-11-16): a temporary detached worktree of the tag
-- v3.6.0 (`git worktree add --detach <scratch>/v360 v3.6.0`), with a
-- throwaway unit file there run as `lua test/run.lua <its filter>` (Lua
-- 5.3.6), then the worktree removed with `git worktree remove`. Everything
-- was set through 3.6.0's own code. The file seeds math.randomseed(37),
-- runs h.load_strata() and h.finish_startup(context), then sets a state:
-- h.scramble_state(37) (3.6.0's helper: every voice's source, params, grain
-- and crossmod values); v1_source 2 (buffer 1) and v1_buf_scan 0.5; voice
-- 2's step 3 at level 9 with prob 40, notes {0, 7} and ratchet 3; LFO 1 on
-- at destination index 12 of 3.6.0's list with depth 40, and LFO 2 at index
-- 20; cc_out1_source and crow_out1_source at "pressure" (option 29); macro 1's
-- first target reverb_mix 0.2-0.8; matrix routing 1 from macro1 to
-- v3_grain_pitch at depth 40. It captures scene 1, then runs
-- h.scramble_state(38), captures scene 4, names it "four" and saves the
-- scenes (save_scenes_to_disk). It sets the state again and writes the PSET
-- with params:write(<data>/strata-05.pset, "three six"), which writes the
-- three side files. scenes.data is the data folder's strata/scenes.data
-- after that, and the other four are the strata-05.* files.
return {
  ["scenes.data"] = [==[
return {
-- Table: {1}
{
   ["scenes"]={2},
   ["version"]=7,
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
   ["delay_feedback"]=0.4,
   ["delay_mix"]=0.0,
   ["delay_time"]=0.375,
   ["drift_amount"]=0.01,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["frozen"]={35},
   ["gesture_1_play"]=0,
   ["gesture_2_play"]=0,
   ["gesture_3_play"]=0,
   ["gesture_4_play"]=0,
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
   ["steps"]={39},
   ["strata_lfo1"]=1,
   ["strata_lfo1_depth"]=40,
   ["strata_lfo1_depth_mod"]=1,
   ["strata_lfo1_depth_mod_amt"]=0,
   ["strata_lfo1_dest"]=12,
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
   ["strata_lfo2_dest"]=20,
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
   ["strata_lfo3_dest"]=1,
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
   ["strata_lfo4_dest"]=1,
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
   ["strata_lfo5_dest"]=1,
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
   ["strata_lfo6_dest"]=1,
   ["strata_lfo6_division"]=13,
   ["strata_lfo6_mode"]=1,
   ["strata_lfo6_offset"]=0,
   ["strata_lfo6_phase"]=0,
   ["strata_lfo6_rate"]=0.25,
   ["strata_lfo6_rate_mod"]=1,
   ["strata_lfo6_rate_mod_amt"]=0,
   ["strata_lfo6_shape"]=1,
   ["tempo"]=120,
   ["voices"]={40},
},
-- Table: {20}
{
},
-- Table: {21}
{
},
-- Table: {22}
{
   ["delay_feedback"]=0.4,
   ["delay_mix"]=0.0,
   ["delay_time"]=0.375,
   ["drift_amount"]=0.01,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["frozen"]={41},
   ["gesture_1_play"]=0,
   ["gesture_2_play"]=0,
   ["gesture_3_play"]=0,
   ["gesture_4_play"]=0,
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
   ["macros"]={42},
   ["master_density"]=1.0,
   ["matrix"]={43},
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
   ["patterns"]={44},
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
   ["steps"]={45},
   ["strata_lfo1"]=1,
   ["strata_lfo1_depth"]=40,
   ["strata_lfo1_depth_mod"]=1,
   ["strata_lfo1_depth_mod_amt"]=0,
   ["strata_lfo1_dest"]=12,
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
   ["strata_lfo2_dest"]=20,
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
   ["strata_lfo3_dest"]=1,
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
   ["strata_lfo4_dest"]=1,
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
   ["strata_lfo5_dest"]=1,
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
   ["strata_lfo6_dest"]=1,
   ["strata_lfo6_division"]=13,
   ["strata_lfo6_mode"]=1,
   ["strata_lfo6_offset"]=0,
   ["strata_lfo6_phase"]=0,
   ["strata_lfo6_rate"]=0.25,
   ["strata_lfo6_rate_mod"]=1,
   ["strata_lfo6_rate_mod_amt"]=0,
   ["strata_lfo6_shape"]=1,
   ["tempo"]=120,
   ["voices"]={46},
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
   {47},
},
-- Table: {37}
{
   {48},
},
-- Table: {38}
{
   {49},
   {50},
   {51},
   {52},
   {53},
   {54},
   {55},
},
-- Table: {39}
{
   {56},
   {57},
   {58},
   {59},
   {60},
   {61},
   {62},
},
-- Table: {40}
{
   {63},
   {64},
   {65},
   {66},
   {67},
   {68},
   {69},
},
-- Table: {41}
{
   false,
   false,
   false,
   false,
   false,
   false,
   false,
},
-- Table: {42}
{
   {70},
},
-- Table: {43}
{
   {71},
},
-- Table: {44}
{
   {72},
   {73},
   {74},
   {75},
   {76},
   {77},
   {78},
},
-- Table: {45}
{
   {79},
   {80},
   {81},
   {82},
   {83},
   {84},
   {85},
},
-- Table: {46}
{
   {86},
   {87},
   {88},
   {89},
   {90},
   {91},
   {92},
},
-- Table: {47}
{
   {93},
},
-- Table: {48}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
},
-- Table: {49}
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
-- Table: {50}
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
-- Table: {51}
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
-- Table: {52}
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
},
-- Table: {57}
{
   [3]={94},
},
-- Table: {58}
{
},
-- Table: {59}
{
},
-- Table: {60}
{
},
-- Table: {61}
{
},
-- Table: {62}
{
},
-- Table: {63}
{
   ["active"]=true,
   ["crossmod"]={95},
   ["extras"]={96},
   ["grain"]={97},
   ["params"]={98},
   ["source"]=2,
},
-- Table: {64}
{
   ["active"]=true,
   ["crossmod"]={99},
   ["extras"]={100},
   ["grain"]={101},
   ["params"]={102},
   ["source"]=10,
},
-- Table: {65}
{
   ["active"]=false,
   ["crossmod"]={103},
   ["extras"]={104},
   ["grain"]={105},
   ["params"]={106},
   ["source"]=4,
},
-- Table: {66}
{
   ["active"]=false,
   ["crossmod"]={107},
   ["extras"]={108},
   ["grain"]={109},
   ["params"]={110},
   ["source"]=10,
},
-- Table: {67}
{
   ["active"]=false,
   ["crossmod"]={111},
   ["extras"]={112},
   ["grain"]={113},
   ["params"]={114},
   ["source"]=5,
},
-- Table: {68}
{
   ["active"]=false,
   ["crossmod"]={115},
   ["extras"]={116},
   ["grain"]={117},
   ["params"]={118},
   ["source"]=5,
},
-- Table: {69}
{
   ["active"]=false,
   ["crossmod"]={119},
   ["extras"]={120},
   ["grain"]={121},
   ["params"]={122},
   ["source"]=9,
},
-- Table: {70}
{
   {123},
},
-- Table: {71}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
},
-- Table: {72}
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
-- Table: {73}
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
-- Table: {74}
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
-- Table: {75}
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
-- Table: {76}
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
-- Table: {77}
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
-- Table: {78}
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
-- Table: {79}
{
},
-- Table: {80}
{
   [3]={124},
},
-- Table: {81}
{
},
-- Table: {82}
{
},
-- Table: {83}
{
},
-- Table: {84}
{
},
-- Table: {85}
{
},
-- Table: {86}
{
   ["active"]=true,
   ["crossmod"]={125},
   ["extras"]={126},
   ["grain"]={127},
   ["params"]={128},
   ["source"]=2,
},
-- Table: {87}
{
   ["active"]=true,
   ["crossmod"]={129},
   ["extras"]={130},
   ["grain"]={131},
   ["params"]={132},
   ["source"]=2,
},
-- Table: {88}
{
   ["active"]=false,
   ["crossmod"]={133},
   ["extras"]={134},
   ["grain"]={135},
   ["params"]={136},
   ["source"]=3,
},
-- Table: {89}
{
   ["active"]=false,
   ["crossmod"]={137},
   ["extras"]={138},
   ["grain"]={139},
   ["params"]={140},
   ["source"]=4,
},
-- Table: {90}
{
   ["active"]=false,
   ["crossmod"]={141},
   ["extras"]={142},
   ["grain"]={143},
   ["params"]={144},
   ["source"]=10,
},
-- Table: {91}
{
   ["active"]=false,
   ["crossmod"]={145},
   ["extras"]={146},
   ["grain"]={147},
   ["params"]={148},
   ["source"]=4,
},
-- Table: {92}
{
   ["active"]=false,
   ["crossmod"]={149},
   ["extras"]={150},
   ["grain"]={151},
   ["params"]={152},
   ["source"]=9,
},
-- Table: {93}
{
   ["id"]="reverb_mix",
   ["max"]=0.8,
   ["min"]=0.2,
},
-- Table: {94}
{
   ["notes"]={153},
   ["prob"]=40,
   ["ratchet"]=3,
},
-- Table: {95}
{
   ["slot1"]={154},
   ["slot2"]={155},
   ["slot3"]={156},
   ["speed"]=6.5,
},
-- Table: {96}
{
   ["attack"]=4.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=8.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {97}
{
   ["buf_pos"]=0.88376089232042,
   ["buf_rate"]=1.2617666865699,
   ["buf_scan"]=0.5,
   ["density"]=46,
   ["env"]=5,
   ["mode"]=1,
   ["pitch"]=1.1569861369208,
   ["size"]=0.24,
   ["spread"]=0.31,
},
-- Table: {98}
{
   ["amp"]=0.3,
   ["freq"]=100,
   ["mod1"]=0.1,
   ["mod2"]=0.15,
   ["noise"]=0.5,
   ["pan"]=0,
   ["rq"]=0.1,
},
-- Table: {99}
{
   ["slot1"]={157},
   ["slot2"]={158},
   ["slot3"]={159},
   ["speed"]=25.0,
},
-- Table: {100}
{
   ["attack"]=5.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=10.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {101}
{
   ["buf_pos"]=0.63985030446202,
   ["buf_rate"]=3.3225051276386,
   ["buf_scan"]=1.99,
   ["density"]=6,
   ["env"]=4,
   ["mode"]=1,
   ["pitch"]=0.8303355621174,
   ["size"]=0.09,
   ["spread"]=0.18,
},
-- Table: {102}
{
   ["amp"]=0.25,
   ["freq"]=80,
   ["index"]=2,
   ["modFreq"]=0.05,
   ["pan"]=0,
   ["ratio"]=1.5,
},
-- Table: {103}
{
   ["slot1"]={160},
   ["slot2"]={161},
   ["slot3"]={162},
   ["speed"]=22.6,
},
-- Table: {104}
{
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=6.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {105}
{
   ["buf_pos"]=0.44767346419394,
   ["buf_rate"]=2.8429362874012,
   ["buf_scan"]=1.41,
   ["density"]=85,
   ["env"]=4,
   ["mode"]=1,
   ["pitch"]=0.82320040464401,
   ["size"]=0.07,
   ["spread"]=0.88,
},
-- Table: {106}
{
   ["amp"]=0.3,
   ["fold"]=1,
   ["freq"]=60,
   ["mod"]=0.2,
   ["pan"]=0,
},
-- Table: {107}
{
   ["slot1"]={163},
   ["slot2"]={164},
   ["slot3"]={165},
   ["speed"]=30.7,
},
-- Table: {108}
{
   ["attack"]=8.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=12.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {109}
{
   ["buf_pos"]=0.20875029452145,
   ["buf_rate"]=3.2190005187877,
   ["buf_scan"]=-1.15,
   ["density"]=41,
   ["env"]=3,
   ["mode"]=1,
   ["pitch"]=0.95413800235838,
   ["size"]=0.35,
   ["spread"]=0.93,
},
-- Table: {110}
{
   ["amp"]=0.4,
   ["drift"]=0.02,
   ["freq"]=40,
},
-- Table: {111}
{
   ["slot1"]={166},
   ["slot2"]={167},
   ["slot3"]={168},
   ["speed"]=13.8,
},
-- Table: {112}
{
   ["attack"]=2.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=4.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {113}
{
   ["buf_pos"]=0.18713295087218,
   ["buf_rate"]=2.7889526732033,
   ["buf_scan"]=0.78,
   ["density"]=24,
   ["env"]=4,
   ["mode"]=2,
   ["pitch"]=2.0007094079629,
   ["size"]=0.32,
   ["spread"]=0.97,
},
-- Table: {114}
{
   ["amp"]=0.3,
   ["cutoff"]=2000,
   ["freq"]=120,
   ["pan"]=0,
   ["res"]=0.8,
   ["width"]=0.5,
},
-- Table: {115}
{
   ["slot1"]={169},
   ["slot2"]={170},
   ["slot3"]={171},
   ["speed"]=3.8,
},
-- Table: {116}
{
   ["attack"]=0.01,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=2.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {117}
{
   ["buf_pos"]=0.38693164614961,
   ["buf_rate"]=3.989853091538,
   ["buf_scan"]=0.92,
   ["density"]=16,
   ["env"]=1,
   ["mode"]=1,
   ["pitch"]=1.0790496096015,
   ["size"]=0.12,
   ["spread"]=0.3,
},
-- Table: {118}
{
   ["amp"]=0.35,
   ["damping"]=0.5,
   ["decay"]=4,
   ["excite"]=0.3,
   ["freq"]=200,
   ["pan"]=0,
},
-- Table: {119}
{
   ["slot1"]={172},
   ["slot2"]={173},
   ["slot3"]={174},
   ["speed"]=37.7,
},
-- Table: {120}
{
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=5.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {121}
{
   ["buf_pos"]=0.14384770812467,
   ["buf_rate"]=3.316581619205,
   ["buf_scan"]=-0.65,
   ["density"]=69,
   ["env"]=5,
   ["mode"]=2,
   ["pitch"]=2.3221493829042,
   ["size"]=0.2,
   ["spread"]=0.4,
},
-- Table: {122}
{
   ["amp"]=0.25,
   ["brightness"]=0.5,
   ["freq"]=300,
   ["mod"]=0.2,
   ["pan"]=0,
   ["ratio"]=1.618,
},
-- Table: {123}
{
   ["id"]="reverb_mix",
   ["max"]=0.8,
   ["min"]=0.2,
},
-- Table: {124}
{
   ["notes"]={175},
   ["prob"]=40,
   ["ratchet"]=3,
},
-- Table: {125}
{
   ["slot1"]={176},
   ["slot2"]={177},
   ["slot3"]={178},
   ["speed"]=21.4,
},
-- Table: {126}
{
   ["attack"]=4.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=8.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {127}
{
   ["buf_pos"]=0.18037493992597,
   ["buf_rate"]=2.4056922304444,
   ["buf_scan"]=-1.27,
   ["density"]=62,
   ["env"]=4,
   ["mode"]=1,
   ["pitch"]=1.8796267993748,
   ["size"]=0.31,
   ["spread"]=0.32,
},
-- Table: {128}
{
   ["amp"]=0.3,
   ["freq"]=100,
   ["mod1"]=0.1,
   ["mod2"]=0.15,
   ["noise"]=0.5,
   ["pan"]=0,
   ["rq"]=0.1,
},
-- Table: {129}
{
   ["slot1"]={179},
   ["slot2"]={180},
   ["slot3"]={181},
   ["speed"]=26.6,
},
-- Table: {130}
{
   ["attack"]=5.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=10.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {131}
{
   ["buf_pos"]=0.29486723989248,
   ["buf_rate"]=2.1802228855668,
   ["buf_scan"]=-0.05,
   ["density"]=66,
   ["env"]=5,
   ["mode"]=2,
   ["pitch"]=1.1263721110299,
   ["size"]=0.32,
   ["spread"]=0.77,
},
-- Table: {132}
{
   ["amp"]=0.25,
   ["freq"]=80,
   ["index"]=2,
   ["modFreq"]=0.05,
   ["pan"]=0,
   ["ratio"]=1.5,
},
-- Table: {133}
{
   ["slot1"]={182},
   ["slot2"]={183},
   ["slot3"]={184},
   ["speed"]=37.2,
},
-- Table: {134}
{
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=6.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {135}
{
   ["buf_pos"]=0.96105811418965,
   ["buf_rate"]=2.6733098252444,
   ["buf_scan"]=0.31,
   ["density"]=3,
   ["env"]=3,
   ["mode"]=1,
   ["pitch"]=1.3627874217927,
   ["size"]=0.09,
   ["spread"]=0.09,
},
-- Table: {136}
{
   ["amp"]=0.3,
   ["fold"]=1,
   ["freq"]=60,
   ["mod"]=0.2,
   ["pan"]=0,
},
-- Table: {137}
{
   ["slot1"]={185},
   ["slot2"]={186},
   ["slot3"]={187},
   ["speed"]=20.4,
},
-- Table: {138}
{
   ["attack"]=8.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=12.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {139}
{
   ["buf_pos"]=0.59621634939685,
   ["buf_rate"]=3.764861392905,
   ["buf_scan"]=-0.02,
   ["density"]=38,
   ["env"]=2,
   ["mode"]=2,
   ["pitch"]=1.0204033590853,
   ["size"]=0.14,
   ["spread"]=0.54,
},
-- Table: {140}
{
   ["amp"]=0.4,
   ["drift"]=0.02,
   ["freq"]=40,
},
-- Table: {141}
{
   ["slot1"]={188},
   ["slot2"]={189},
   ["slot3"]={190},
   ["speed"]=25.9,
},
-- Table: {142}
{
   ["attack"]=2.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=4.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {143}
{
   ["buf_pos"]=0.078248750418425,
   ["buf_rate"]=1.2586972423596,
   ["buf_scan"]=-1.65,
   ["density"]=19,
   ["env"]=3,
   ["mode"]=2,
   ["pitch"]=2.4506568564102,
   ["size"]=0.2,
   ["spread"]=0.6,
},
-- Table: {144}
{
   ["amp"]=0.3,
   ["cutoff"]=2000,
   ["freq"]=120,
   ["pan"]=0,
   ["res"]=0.8,
   ["width"]=0.5,
},
-- Table: {145}
{
   ["slot1"]={191},
   ["slot2"]={192},
   ["slot3"]={193},
   ["speed"]=30.2,
},
-- Table: {146}
{
   ["attack"]=0.01,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=2.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {147}
{
   ["buf_pos"]=0.97597662825137,
   ["buf_rate"]=1.1055643766886,
   ["buf_scan"]=0.67,
   ["density"]=73,
   ["env"]=3,
   ["mode"]=1,
   ["pitch"]=1.0753826471046,
   ["size"]=0.18,
   ["spread"]=0.64,
},
-- Table: {148}
{
   ["amp"]=0.35,
   ["damping"]=0.5,
   ["decay"]=4,
   ["excite"]=0.3,
   ["freq"]=200,
   ["pan"]=0,
},
-- Table: {149}
{
   ["slot1"]={194},
   ["slot2"]={195},
   ["slot3"]={196},
   ["speed"]=0.6,
},
-- Table: {150}
{
   ["attack"]=3.0,
   ["bookmark_1"]=0,
   ["bookmark_2"]=0.25,
   ["bookmark_3"]=0.5,
   ["bookmark_4"]=0.75,
   ["custom_interval_1"]=-12,
   ["custom_interval_2"]=0,
   ["custom_interval_3"]=7,
   ["custom_interval_4"]=12,
   ["custom_interval_5"]=19,
   ["delay_send"]=1.0,
   ["filter_freq"]=5000.0,
   ["filter_mix"]=0.0,
   ["filter_res"]=0.5,
   ["filter_type"]=1,
   ["freeze"]=0,
   ["freeze_mode"]=1,
   ["history"]=0,
   ["interval_prob"]=100,
   ["intervals"]=1,
   ["loop_length"]=1,
   ["loop_start"]=0,
   ["mute"]=0,
   ["pan_jitter"]=0.0,
   ["pitch_jitter"]=0.0,
   ["press_depth"]=100,
   ["press_target"]=2,
   ["quantize"]=0,
   ["release"]=5.0,
   ["reverb_send"]=1.0,
   ["reverse"]=0,
   ["seq_division"]=3,
   ["seq_gate"]=1,
   ["seq_gate_length"]=0.5,
   ["seq_gate_release"]=0.1,
   ["seq_length"]=16,
   ["seq_swing"]=50,
   ["size_jitter"]=0.0,
   ["slide_depth"]=50,
   ["slide_target"]=4,
},
-- Table: {151}
{
   ["buf_pos"]=0.94274548720568,
   ["buf_rate"]=3.694831482484,
   ["buf_scan"]=1.64,
   ["density"]=84,
   ["env"]=3,
   ["mode"]=1,
   ["pitch"]=1.6386705404148,
   ["size"]=0.13,
   ["spread"]=0.99,
},
-- Table: {152}
{
   ["amp"]=0.25,
   ["brightness"]=0.5,
   ["freq"]=300,
   ["mod"]=0.2,
   ["pan"]=0,
   ["ratio"]=1.618,
},
-- Table: {153}
{
   0,
   7,
},
-- Table: {154}
{
   ["amp_amt"]=1.83,
   ["freq_amt"]=-1.34,
   ["source"]=5,
},
-- Table: {155}
{
   ["amp_amt"]=0.37,
   ["freq_amt"]=1.7,
   ["source"]=5,
},
-- Table: {156}
{
   ["amp_amt"]=0.76,
   ["freq_amt"]=-0.28,
   ["source"]=4,
},
-- Table: {157}
{
   ["amp_amt"]=1.16,
   ["freq_amt"]=1.99,
   ["source"]=7,
},
-- Table: {158}
{
   ["amp_amt"]=0.7,
   ["freq_amt"]=-0.93,
   ["source"]=1,
},
-- Table: {159}
{
   ["amp_amt"]=1.94,
   ["freq_amt"]=0.87,
   ["source"]=6,
},
-- Table: {160}
{
   ["amp_amt"]=-0.37,
   ["freq_amt"]=1.37,
   ["source"]=0,
},
-- Table: {161}
{
   ["amp_amt"]=0.35,
   ["freq_amt"]=1.61,
   ["source"]=0,
},
-- Table: {162}
{
   ["amp_amt"]=1.77,
   ["freq_amt"]=1.12,
   ["source"]=6,
},
-- Table: {163}
{
   ["amp_amt"]=-1.63,
   ["freq_amt"]=-0.53,
   ["source"]=7,
},
-- Table: {164}
{
   ["amp_amt"]=0.16,
   ["freq_amt"]=-1.76,
   ["source"]=1,
},
-- Table: {165}
{
   ["amp_amt"]=-0.33,
   ["freq_amt"]=1.61,
   ["source"]=7,
},
-- Table: {166}
{
   ["amp_amt"]=1.38,
   ["freq_amt"]=0.98,
   ["source"]=3,
},
-- Table: {167}
{
   ["amp_amt"]=1.08,
   ["freq_amt"]=-1.4,
   ["source"]=5,
},
-- Table: {168}
{
   ["amp_amt"]=-1.77,
   ["freq_amt"]=-1.51,
   ["source"]=1,
},
-- Table: {169}
{
   ["amp_amt"]=-1.19,
   ["freq_amt"]=1.55,
   ["source"]=7,
},
-- Table: {170}
{
   ["amp_amt"]=-1.32,
   ["freq_amt"]=-1.53,
   ["source"]=4,
},
-- Table: {171}
{
   ["amp_amt"]=-1.5,
   ["freq_amt"]=0.3,
   ["source"]=1,
},
-- Table: {172}
{
   ["amp_amt"]=-1.17,
   ["freq_amt"]=0.57,
   ["source"]=7,
},
-- Table: {173}
{
   ["amp_amt"]=0.02,
   ["freq_amt"]=1.2,
   ["source"]=5,
},
-- Table: {174}
{
   ["amp_amt"]=0.86,
   ["freq_amt"]=0.84,
   ["source"]=5,
},
-- Table: {175}
{
   0,
   7,
},
-- Table: {176}
{
   ["amp_amt"]=-0.33,
   ["freq_amt"]=-0.6,
   ["source"]=5,
},
-- Table: {177}
{
   ["amp_amt"]=1.14,
   ["freq_amt"]=0.36,
   ["source"]=3,
},
-- Table: {178}
{
   ["amp_amt"]=1.97,
   ["freq_amt"]=-1.45,
   ["source"]=1,
},
-- Table: {179}
{
   ["amp_amt"]=-1.46,
   ["freq_amt"]=-1.16,
   ["source"]=2,
},
-- Table: {180}
{
   ["amp_amt"]=-0.16,
   ["freq_amt"]=1.28,
   ["source"]=4,
},
-- Table: {181}
{
   ["amp_amt"]=1.54,
   ["freq_amt"]=-0.18,
   ["source"]=1,
},
-- Table: {182}
{
   ["amp_amt"]=0.82,
   ["freq_amt"]=0.09,
   ["source"]=2,
},
-- Table: {183}
{
   ["amp_amt"]=-0.09,
   ["freq_amt"]=-1.29,
   ["source"]=6,
},
-- Table: {184}
{
   ["amp_amt"]=-1.56,
   ["freq_amt"]=0.09,
   ["source"]=6,
},
-- Table: {185}
{
   ["amp_amt"]=-0.88,
   ["freq_amt"]=-0.78,
   ["source"]=6,
},
-- Table: {186}
{
   ["amp_amt"]=-0.51,
   ["freq_amt"]=-0.68,
   ["source"]=3,
},
-- Table: {187}
{
   ["amp_amt"]=-0.48,
   ["freq_amt"]=0.66,
   ["source"]=6,
},
-- Table: {188}
{
   ["amp_amt"]=0.19,
   ["freq_amt"]=1.73,
   ["source"]=4,
},
-- Table: {189}
{
   ["amp_amt"]=-1.42,
   ["freq_amt"]=1.48,
   ["source"]=6,
},
-- Table: {190}
{
   ["amp_amt"]=0.72,
   ["freq_amt"]=-1.02,
   ["source"]=2,
},
-- Table: {191}
{
   ["amp_amt"]=0.59,
   ["freq_amt"]=-0.41,
   ["source"]=5,
},
-- Table: {192}
{
   ["amp_amt"]=-1.02,
   ["freq_amt"]=0.33,
   ["source"]=6,
},
-- Table: {193}
{
   ["amp_amt"]=1.58,
   ["freq_amt"]=-1.42,
   ["source"]=1,
},
-- Table: {194}
{
   ["amp_amt"]=0.13,
   ["freq_amt"]=0.63,
   ["source"]=0,
},
-- Table: {195}
{
   ["amp_amt"]=-1.3,
   ["freq_amt"]=-0.46,
   ["source"]=6,
},
-- Table: {196}
{
   ["amp_amt"]=-0.79,
   ["freq_amt"]=-1.65,
   ["source"]=2,
},
}]==],
  ["strata-05.pset"] = [==[
-- three six
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
"strata_pset_format": 2
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
"strata_fx": 13
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
"strata_lfo_1": 13
"strata_lfo1": 1
"strata_lfo1_dest": 12
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
"strata_lfo_2": 13
"strata_lfo2": 0
"strata_lfo2_dest": 20
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
"strata_lfo_3": 13
"strata_lfo3": 0
"strata_lfo3_dest": 1
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
"strata_lfo_4": 13
"strata_lfo4": 0
"strata_lfo4_dest": 1
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
"strata_lfo_5": 13
"strata_lfo5": 0
"strata_lfo5_dest": 1
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
"strata_lfo_6": 13
"strata_lfo6": 0
"strata_lfo6_dest": 1
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
"cc_out1_source_key": pressure
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
"crow_out1_source_key": pressure
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
"strata_seq": 7
"seq_chain": 0
"seq_chain_from": 1
"seq_chain_scenes": 2
"seq_chain_bars": 4
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
"v1_source": 2
"v1_buf_pos": 0.88376089232042
"v1_buf_rate": 1.2617666865699
"v1_buf_scan": 0.5
"v1_grain_size": 0.24
"v1_grain_density": 46
"v1_grain_pitch": 1.1569861369208
"v1_grain_spread": 0.31
"v1_grain_env": 5
"v1_grain_mode": 1
"v1_mod_source_1": 5
"v1_mod_amp_amt_1": 1.83
"v1_mod_freq_amt_1": -1.34
"v1_mod_source_2": 5
"v1_mod_amp_amt_2": 0.37
"v1_mod_freq_amt_2": 1.7
"v1_mod_source_3": 4
"v1_mod_amp_amt_3": 0.76
"v1_mod_freq_amt_3": -0.28
"v1_mod_speed": 6.5
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
"v1_note_cap": 8
"v1_attack": 4.0
"v1_release": 8.0
"v1_press_target": 2
"v1_press_depth": 100
"v1_slide_target": 4
"v1_slide_depth": 50
"v1_seq_length": 16
"v1_seq_division": 3
"v1_seq_gate": 1
"v1_seq_gate_length": 0.5
"v1_seq_gate_release": 0.1
"v1_seq_swing": 50
"v2_quantize": 0
"v2_freq": 80.0
"v2_ratio": 1.5
"v2_index": 2.0
"v2_modFreq": 0.05
"v2_amp": 0.25
"v2_pan": 0.0
"v2_source": 10
"v2_buf_pos": 0.63985030446202
"v2_buf_rate": 3.3225051276386
"v2_buf_scan": 1.99
"v2_grain_size": 0.09
"v2_grain_density": 6
"v2_grain_pitch": 0.8303355621174
"v2_grain_spread": 0.18
"v2_grain_env": 4
"v2_grain_mode": 1
"v2_mod_source_1": 7
"v2_mod_amp_amt_1": 1.16
"v2_mod_freq_amt_1": 1.99
"v2_mod_source_2": 1
"v2_mod_amp_amt_2": 0.7
"v2_mod_freq_amt_2": -0.93
"v2_mod_source_3": 6
"v2_mod_amp_amt_3": 1.94
"v2_mod_freq_amt_3": 0.87
"v2_mod_speed": 25.0
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
"v2_note_cap": 8
"v2_attack": 5.0
"v2_release": 10.0
"v2_press_target": 2
"v2_press_depth": 100
"v2_slide_target": 4
"v2_slide_depth": 50
"v2_seq_length": 16
"v2_seq_division": 3
"v2_seq_gate": 1
"v2_seq_gate_length": 0.5
"v2_seq_gate_release": 0.1
"v2_seq_swing": 50
"v3_quantize": 0
"v3_freq": 60.0
"v3_fold": 1.0
"v3_mod": 0.2
"v3_amp": 0.3
"v3_pan": 0.0
"v3_source": 4
"v3_buf_pos": 0.44767346419394
"v3_buf_rate": 2.8429362874012
"v3_buf_scan": 1.41
"v3_grain_size": 0.07
"v3_grain_density": 85
"v3_grain_pitch": 0.82320040464401
"v3_grain_spread": 0.88
"v3_grain_env": 4
"v3_grain_mode": 1
"v3_mod_source_1": 0
"v3_mod_amp_amt_1": -0.37
"v3_mod_freq_amt_1": 1.37
"v3_mod_source_2": 0
"v3_mod_amp_amt_2": 0.35
"v3_mod_freq_amt_2": 1.61
"v3_mod_source_3": 6
"v3_mod_amp_amt_3": 1.77
"v3_mod_freq_amt_3": 1.12
"v3_mod_speed": 22.6
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
"v3_note_cap": 8
"v3_attack": 3.0
"v3_release": 6.0
"v3_press_target": 2
"v3_press_depth": 100
"v3_slide_target": 4
"v3_slide_depth": 50
"v3_seq_length": 16
"v3_seq_division": 3
"v3_seq_gate": 1
"v3_seq_gate_length": 0.5
"v3_seq_gate_release": 0.1
"v3_seq_swing": 50
"v4_quantize": 0
"v4_freq": 40.0
"v4_drift": 0.02
"v4_amp": 0.4
"v4_source": 10
"v4_buf_pos": 0.20875029452145
"v4_buf_rate": 3.2190005187877
"v4_buf_scan": -1.15
"v4_grain_size": 0.35
"v4_grain_density": 41
"v4_grain_pitch": 0.95413800235838
"v4_grain_spread": 0.93
"v4_grain_env": 3
"v4_grain_mode": 1
"v4_mod_source_1": 7
"v4_mod_amp_amt_1": -1.63
"v4_mod_freq_amt_1": -0.53
"v4_mod_source_2": 1
"v4_mod_amp_amt_2": 0.16
"v4_mod_freq_amt_2": -1.76
"v4_mod_source_3": 7
"v4_mod_amp_amt_3": -0.33
"v4_mod_freq_amt_3": 1.61
"v4_mod_speed": 30.7
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
"v4_note_cap": 8
"v4_attack": 8.0
"v4_release": 12.0
"v4_press_target": 2
"v4_press_depth": 100
"v4_slide_target": 4
"v4_slide_depth": 50
"v4_seq_length": 16
"v4_seq_division": 3
"v4_seq_gate": 1
"v4_seq_gate_length": 0.5
"v4_seq_gate_release": 0.1
"v4_seq_swing": 50
"v5_quantize": 0
"v5_freq": 120.0
"v5_width": 0.5
"v5_cutoff": 2000
"v5_res": 0.8
"v5_amp": 0.3
"v5_pan": 0.0
"v5_source": 5
"v5_buf_pos": 0.18713295087218
"v5_buf_rate": 2.7889526732033
"v5_buf_scan": 0.78
"v5_grain_size": 0.32
"v5_grain_density": 24
"v5_grain_pitch": 2.0007094079629
"v5_grain_spread": 0.97
"v5_grain_env": 4
"v5_grain_mode": 2
"v5_mod_source_1": 3
"v5_mod_amp_amt_1": 1.38
"v5_mod_freq_amt_1": 0.98
"v5_mod_source_2": 5
"v5_mod_amp_amt_2": 1.08
"v5_mod_freq_amt_2": -1.4
"v5_mod_source_3": 1
"v5_mod_amp_amt_3": -1.77
"v5_mod_freq_amt_3": -1.51
"v5_mod_speed": 13.8
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
"v5_note_cap": 8
"v5_attack": 2.0
"v5_release": 4.0
"v5_press_target": 2
"v5_press_depth": 100
"v5_slide_target": 4
"v5_slide_depth": 50
"v5_seq_length": 16
"v5_seq_division": 3
"v5_seq_gate": 1
"v5_seq_gate_length": 0.5
"v5_seq_gate_release": 0.1
"v5_seq_swing": 50
"v6_quantize": 0
"v6_freq": 200.0
"v6_decay": 4.0
"v6_damping": 0.5
"v6_excite": 0.3
"v6_amp": 0.35
"v6_pan": 0.0
"v6_source": 5
"v6_buf_pos": 0.38693164614961
"v6_buf_rate": 3.989853091538
"v6_buf_scan": 0.92
"v6_grain_size": 0.12
"v6_grain_density": 16
"v6_grain_pitch": 1.0790496096015
"v6_grain_spread": 0.3
"v6_grain_env": 1
"v6_grain_mode": 1
"v6_mod_source_1": 7
"v6_mod_amp_amt_1": -1.19
"v6_mod_freq_amt_1": 1.55
"v6_mod_source_2": 4
"v6_mod_amp_amt_2": -1.32
"v6_mod_freq_amt_2": -1.53
"v6_mod_source_3": 1
"v6_mod_amp_amt_3": -1.5
"v6_mod_freq_amt_3": 0.3
"v6_mod_speed": 3.8
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
"v6_note_cap": 8
"v6_attack": 0.01
"v6_release": 2.0
"v6_press_target": 2
"v6_press_depth": 100
"v6_slide_target": 4
"v6_slide_depth": 50
"v6_seq_length": 16
"v6_seq_division": 3
"v6_seq_gate": 1
"v6_seq_gate_length": 0.5
"v6_seq_gate_release": 0.1
"v6_seq_swing": 50
"v7_quantize": 0
"v7_freq": 300.0
"v7_ratio": 1.618
"v7_mod": 0.2
"v7_brightness": 0.5
"v7_amp": 0.25
"v7_pan": 0.0
"v7_source": 9
"v7_buf_pos": 0.14384770812467
"v7_buf_rate": 3.316581619205
"v7_buf_scan": -0.65
"v7_grain_size": 0.2
"v7_grain_density": 69
"v7_grain_pitch": 2.3221493829042
"v7_grain_spread": 0.4
"v7_grain_env": 5
"v7_grain_mode": 2
"v7_mod_source_1": 7
"v7_mod_amp_amt_1": -1.17
"v7_mod_freq_amt_1": 0.57
"v7_mod_source_2": 5
"v7_mod_amp_amt_2": 0.02
"v7_mod_freq_amt_2": 1.2
"v7_mod_source_3": 5
"v7_mod_amp_amt_3": 0.86
"v7_mod_freq_amt_3": 0.84
"v7_mod_speed": 37.7
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
"v7_note_cap": 8
"v7_attack": 3.0
"v7_release": 5.0
"v7_press_target": 2
"v7_press_depth": 100
"v7_slide_target": 4
"v7_slide_depth": 50
"v7_seq_length": 16
"v7_seq_division": 3
"v7_seq_gate": 1
"v7_seq_gate_length": 0.5
"v7_seq_gate_release": 0.1
"v7_seq_swing": 50
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
   ["version"]=1,
},
-- Table: {2}
{
   {3},
},
-- Table: {3}
{
   ["dest"]="v3_grain_pitch",
   ["source"]="macro1",
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
}
