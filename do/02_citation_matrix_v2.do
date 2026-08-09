*** 0. 设置工作目录与环境 ***
clear all
set more off
cd "data"

*** 1. 导入清洗好的长格式引用数据 ***
* 数据结构假设：citing_id (引用方), cited_id (被引方), patent_year, Weight (引用次数/强度)
use "firm_citation_matrix_long_format_raw.dta", clear

* 确保没有自引
drop if citing_company_id == cited_company_id

*** 2. 初始化用于存储 Stata 计算结果的临时文件 ***
tempfile final_stata_metrics
save `final_stata_metrics', emptyok

*** 3. 循环：5年滚动窗口计算 (例如 2012-2023) ***
local start_year = 2012
local end_year = 2023 

forval t = `start_year'/`end_year' {
    di ">> 正在处理年份 `t' (窗口 `t-4' 到 `t')..."
    
    * ---------------------------------------------------------
    * A. 数据切片：获取 5 年窗口内的数据
    * ---------------------------------------------------------
    use "firm_citation_matrix_long_format_raw.dta", clear
    local t_minus_4 = `t' - 4
    keep if patent_year >= `t_minus_4' & patent_year <= `t'
    
    * 聚合权重：计算该窗口内 A 对 B 的总引用次数
    collapse (sum) total_weight=Weight, by(citing_company_id cited_company_id)
    
    * 保存当前窗口的边列表（用于后续使用）
    tempfile window_edges
    save `window_edges'
    
    * ---------------------------------------------------------
    * B. Stata 计算：加权出度 (吸收能力) & 加权入度 (源头地位)
    * ---------------------------------------------------------
    
    * [计算加权出度] (Out-degree)
    use `window_edges', clear
    collapse (sum) w_out_degree=total_weight, by(citing_company_id)
    rename citing_company_id firm_id
    tempfile out_deg
    save `out_deg'
    
    * [计算加权入度] (In-degree)
    use `window_edges', clear
    collapse (sum) w_in_degree=total_weight, by(cited_company_id)
    rename cited_company_id firm_id
    tempfile in_deg
    save `in_deg'
    
    * [合并出度和入度到节点列表]
    * 这一步是为了确保既有引用别人、也有被别人引用的企业都在列表中
    use `out_deg', clear
    merge 1:1 firm_id using `in_deg'
    drop _merge
    
    * 缺失值置0 (merge产生的缺失意味着该指标为0)
    replace w_out_degree = 0 if w_out_degree == .
    replace w_in_degree = 0 if w_in_degree == .
    
    * 标记年份并追加到总文件
    gen patent_year = `t'
    append using `final_stata_metrics'
    save `final_stata_metrics', replace
    
    * ---------------------------------------------------------
    * C. Gephi 导出：生成用于计算结构指标的 CSV
    * ---------------------------------------------------------
    use `window_edges', clear
    
    * [生成两种权重]
    * 1. 原始权重 (RawWeight): 用于 PageRank, 特征向量中心度 (越大越好)
    rename total_weight RawWeight
    
    * 2. 距离权重 (Distance): 用于 中介中心度, 接近中心度 (越小越近)
    * 公式：距离 = 1 / 权重
    gen DistanceCost = 1 / RawWeight
    
    * [重命名为 Gephi 识别格式]
    rename citing_company_id Source
    rename cited_company_id Target
    
    * 导出
    keep Source Target RawWeight DistanceCost
    export delimited using "gephi_edges_5yr_`t'.csv", replace
}

*** 4. 保存 Stata 计算好的基础指标 ***
use `final_stata_metrics', clear
label var w_out_degree "吸收能力(加权出度)"
label var w_in_degree "源头地位(加权入度)"
save "stata_calculated_degree_metrics.dta", replace

di "✅ Stata部分完成：加权出入度已算好，Gephi数据已导出。"


* 假设你现在正打开着这个"割裂"的数据集

* 1. 剔除没有 firm_id 的行（这些是原始引用记录，不需要）
drop if missing(firm_id)

* 2. 剔除多余的变量（这些是原始引用关系的变量，回归用不上）
capture drop citing_company_id cited_company_id Weight 

* 3. 检查数据结构
* 现在应该每一行代表一个"企业-年份"
* 确保没有重复值
duplicates report firm_id patent_year

destring _all,replace

*保留沪深A股
drop if firm_id>200000&firm_id<300000
drop if firm_id>400000&firm_id<500000
drop if firm_id>700000


* 4. 保存为最终的回归用数据
save "Final_Regression_Dataset_Cleaned.dta", replace

di "✅ 数据修复完成！现在每一行都是一个企业的年度指标，可以直接用于回归。"








*** 1. 导入并堆叠 Gephi 的计算结果 ***
clear
tempfile all_gephi_results
save `all_gephi_results', emptyok

local start_year = 2012
local end_year = 2023 

forval t = `start_year'/`end_year' {
    * 假设 Gephi 导出的文件名如下
    capture import delimited "gephi_results_`t'.csv", clear 
    if _rc == 0 {
        * 清理变量名 (根据 Gephi 实际导出名调整)
        * 通常 Gephi 导出包含: id, pageranks, closnesscentrality, betweenesscentrality...
        keep id pageranks closnesscentrality betweenesscentrality eccentricity
        
        rename id firm_id
        rename pageranks page_rank
        rename closnesscentrality closeness
        rename betweenesscentrality betweenness
        
        gen patent_year = `t'
        
        * 归一化中介中心度 (可选，因为Gephi算的是绝对值)
        * 简单归一化：除以当年最大可能连接数，或者直接后续做Z-score
        
        append using `all_gephi_results'
        save `all_gephi_results', replace
    }
}

*** 2. 最终合并：Stata指标 + Gephi指标 ***
use "Final_Regression_Dataset_Cleaned.dta", clear

* 合并 Gephi 数据
merge 1:1 firm_id patent_year using `all_gephi_results'

* 处理未匹配项 (通常是孤立点或计算遗漏)
* _merge == 1: 只有出入度，Gephi没算 (可能是孤立节点) -> 结构指标设为0
foreach var in page_rank closeness betweenness eccentricity {
    replace `var' = 0 if `var' == .
}
drop _merge

* 1. PageRank：缩尾 0.01% (处理最大的 0.01% 极值)
winsor2 page_rank, replace cuts(0 99.99)

* 2. Closeness：标准 1% 缩尾
winsor2 closeness, replace cuts(1 99)

* 3. w_out_degree：标准 1% 缩尾
winsor2 w_out_degree, replace cuts(1 99)

* 1. 定义归一化函数：(x - min) / (max - min)
foreach var in w_out_degree closeness page_rank{
    summarize `var'
    gen norm_`var' = (`var' - r(min)) / (r(max) - r(min))
}

* [核心自变量] 创新网络融入度 (吸收型)
* 使用 Stata 算的pagerank (自身实力) + Gephi 算的接近中心度 (获取速度)
* 交互或乘积 (根据您的理论设定)
* 2. 为了避免 0 值导致乘积消失，通常加一个小数值或平移到 [1, 2]
* 这里直接相乘（假设0代表完全无融入）
gen N_Integration = norm_closeness * norm_page_rank
* 计算综合指标 (几何平均逻辑，体现两个维度的互补性)
gen Integration = norm_w_out_degree * norm_page_rank


* [网络密度] (如果需要控制环境)
* 这需要每年的网络统计数据，通常是常数/年份
* 可以简单用年份虚拟变量控制，或单独导入密度数据

label var N_Integration "创新网络融入度(结构侧)"
label var Integration "创新网络融入度(吸收侧)"

rename firm_id stkcd
rename patent_year year

order stkcd year
destring _all,replace

*保留沪深A股
drop if stkcd>200000&stkcd<300000
drop if stkcd>400000&stkcd<500000
drop if stkcd>700000

save "Final_Regression_Dataset.dta", replace

di "🎉 所有指标构建完成，可直接进行回归分析！"





* 导入数据及清洗
* =============================================================
* 1. 导入数据及清洗 (生成基础 .dta 文件)
* =============================================================
cd "data"

* --- (1) AF_Actual ---
import excel AF_Actual.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Ddate, 1, 4))
gen stkcd = Stkcd
drop Ddate Stkcd
order stkcd year
save AF_Actual.xlsx.dta, replace

* --- (2) CSR_Finidx (这里含有关键的2010年资产!) ---
import excel CSR_Finidx.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Accper, 1, 4))
gen stkcd = Stkcd
drop Accper Stkcd
order stkcd year
save CSR_Finidx.xlsx.dta, replace

* 【关键步骤 A】从 CSR_Finidx 中提取 2010 年的资产数据
* 我们只需要 2010 年的 ID 和 总资产，用来做 2011 年的分母
use CSR_Finidx.xlsx.dta, clear
keep if year == 2010
* 确保 A100000 是数值型
destring A100000, replace force 
* 只保留关键变量
keep stkcd year A100000
* 去重，防止多条记录干扰
duplicates drop stkcd year, force
save "Assets_2010_Only.dta", replace

* --- (3) 其他文件导入 (保持不变) ---
import excel DEBT_INSTITUTIONINFO.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(EndDate, 1, 4))
gen stkcd = Symbol
drop EndDate Symbol
order stkcd year
save DEBT_INSTITUTIONINFO.xlsx.dta, replace

import excel FI_T1.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Accper, 1, 4))
gen stkcd = Stkcd
drop ShortName Accper Source Typrep Stkcd
order stkcd year
save FI_T1.xlsx.dta, replace

import excel FI_T8.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Accper, 1, 4))
gen stkcd = Stkcd
drop ShortName Accper Source Typrep Stkcd
order stkcd year
save FI_T8.xlsx.dta, replace

import excel FS_Comscfd.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Accper, 1, 4))
gen stkcd = Stkcd
drop ShortName Accper Typrep Stkcd
order stkcd year
save FS_Comscfd.xlsx.dta, replace

import excel CG_Ybasic.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Reptdt, 1, 4))
gen stkcd = Stkcd
drop Reptdt Stkcd
order stkcd year
save CG_Ybasic.xlsx.dta, replace

import excel FS_Combas.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Accper, 1, 4))
gen stkcd = Stkcd
drop Accper Stkcd ShortName Typrep
order stkcd year
save FS_Combas.xlsx.dta, replace

import excel FS_Comins.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Accper, 1, 4))
gen stkcd = Stkcd
drop Accper Stkcd ShortName Typrep
order stkcd year
save FS_Comins.xlsx.dta, replace

import excel MC_MarketCompetLevelIndex.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(EndDate, 1, 4))
gen stkcd = Symbol
drop EndDate Symbol
order stkcd year
save MC_MarketCompetLevelIndex.xlsx.dta, replace

import excel FI_T10.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Accper, 1, 4))
gen stkcd = Stkcd
drop Accper Stkcd ShortName Source
order stkcd year
save FI_T10.xlsx.dta, replace

import excel STK_LISTEDCOINFOANL.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(EndDate, 1, 4))
gen stkcd = Symbol
drop EndDate Symbol
order stkcd year
save STK_LISTEDCOINFOANL.xlsx.dta, replace

import excel CG_ManagerShareSalary.xlsx , firstrow clear
labone, nrow(1 2) concat("_")
drop in 1/2
destring _all, replace
gen year = real(substr(Enddate, 1, 4))
gen stkcd = Symbol
drop Enddate Symbol
order stkcd year
save CG_ManagerShareSalary.xlsx.dta, replace


* =============================================================
* 2. 数据合并与变量构建
* =============================================================

* 读取主表 (假设从2011开始)
use "AF_Actual.xlsx.dta", clear

* 合并其他数据
merge 1:1 stkcd year using CSR_Finidx.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using DEBT_INSTITUTIONINFO.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using FI_T1.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using FI_T8.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using FS_Comscfd.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using CG_Ybasic.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using FS_Combas.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using FS_Comins.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using MC_MarketCompetLevelIndex.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using FI_T10.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using STK_LISTEDCOINFOANL.xlsx.dta, nogen keep(1 3)
merge 1:1 stkcd year using CG_ManagerShareSalary.xlsx.dta, nogen keep(1 3)


* 处理日期变量
gen listdate = real(substr(LISTINGDATE, 1, 4))
gen establishdate = real(substr(ESTABLISHDATE, 1, 4))
gen listage = year - listdate
gen establishage = year - establishdate

* 确保 stkcd 是数值型
destring stkcd, replace force

* 【关键步骤 B】在此处追加 2010 年的资产数据
* 这样你的面板里就会有 2010 年的行，且包含 A100000
append using "Assets_2010_Only.dta"

* 设定面板
sort stkcd year
xtset stkcd year

* 检查：此时你应该能看到2010年的行，且A100000有值
* 虽然其他变量可能是空的，但这完全没问题，因为2010年只是用来做分母的

* =============================================================
* 3. 生成核心变量 (恢复最严格的学术定义！)
* =============================================================

* (1) 新增投资 New_Invest_Amt
gen New_Invest_Amt = (C002006000 + C002009000) - (C002003000 + C002004000)
replace New_Invest_Amt = 0 if New_Invest_Amt == .

* (2) 企业规模 Size
* 注意：Richardson 模型中 Size 也是 lagged 变量，所以 2011 年的 Regression 需要 2010 年的 Size
gen Size = ln(A100000)
gen 员工人数 = Y0601b

* (3) 资产负债率 Lev
gen Lev = F011201A

* (4) 上市年限 Age
gen Age = ln(listage + 1)

* (5) 增长率 Growth
gen Growth = F081602C

* (6) 现金持有 Cash
gen Cash = C006000000 / A100000

gen Cashflow = C001000000 / A100000

* (7) 【核心修改】计算 Invest
* 因为现在有了 2010 年的行，L.A100000 在 2011 年就有值了！
* 所以 2011 年的 Invest 能算出来！
gen Invest = New_Invest_Amt / L.A100000

* (8) 公司治理结构
* 管理费用率 ADM
gen ADM = B001210000 / B001101000

* 董事会规模 Board
gen Board = ln(DirectorNumber)

* 董事会独立性 IND
gen IND = IndependentDirectorNumber / DirectorNumber

* (9) 研发投入 RD_Ratio
* 同样使用期初资产 L.A100000
replace RDSpendSum = 0 if RDSpendSum == .
gen RD_Ratio = RDSpendSum / L.A100000
gen TobinQ = F100901A

* =============================================================
* 4. 生成滞后项与回归
* =============================================================

* 生成滞后项
* 逻辑链条闭环：
* 2010年有 Assets -> 2011年算出 Invest -> 2012年算出 l_Invest
foreach var in Growth Lev ROA Age Size Cash Invest TobinQ{
    capture drop l_`var'
    gen l_`var' = L.`var'
}

* 行业处理
* 2010年的行没有行业代码，但没关系，因为它们不进回归
encode Indcd1, gen(industry_id)

* 筛选回归样本 (2012年现在复活了！)
keep if year >= 2012

* 缩尾
local vars Invest l_Growth l_Lev l_ROA l_Age l_Size l_Invest l_Cash l_TobinQ
winsor2 `vars', replace cuts(1 99)


local vars "Size Age Cash Lev Growth Cashflow ADM Board IND"
foreach v in `vars' {
    winsor2 `v', replace cuts(1 99)
}

* 运行回归
* 此时 2012 年的数据应该已经包含在内了
reghdfe Invest l_Growth l_Lev l_ROA l_Age l_Size l_Invest l_Cash l_TobinQ, absorb(industry_id#year) residuals(resid)

* 生成 OverInvest
gen OverInvest = 0
replace OverInvest = resid if resid > 0 & resid != . & e(sample)==1

* 最终检查
winsor2 OverInvest, replace cuts(1 99)
sum OverInvest, detail

* 看看 2012 年是不是有值了
tab year if OverInvest != 0

save "OverInvestment_Data.dta", replace




/* ===================================================
   描述性统计 (分层导出：Panel A & Panel B)
   =================================================== */
clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id)

* ===================================================
* 机制变量 1：专利数据
* ===================================================
merge 1:1 stkcd year using "data/", nogen keep(1 3) 

* 专利缺失代表没专利，补0 (保留了样本)
replace ln_total_patents = 0 if missing(ln_total_patents)
replace ln_dte = 0 if missing(ln_dte)
replace ln_dtu = 0 if missing(ln_dtu)
replace dte_count = 0 if missing(dte_count)
replace dtu_count = 0 if missing(dtu_count)
replace total_patents = 0 if missing(total_patents)

* ===================================================
* 机制变量 2：人力资本数据
* ===================================================
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 基础加总
egen high_edu_count = rowtotal(博士人数 硕士人数 本科人数)
egen low_edu_count = rowtotal(高中及以下人数 专科人数)

gen ln_high_low = ln( high_edu_count / low_edu_count ) if high_edu_count > 0 & low_edu_count > 0
gen hd = ln(high_edu_count) if high_edu_count > 0
gen ld = ln(low_edu_count) if low_edu_count > 0

* 缩尾处理
winsor2 hd ld ln_high_low, replace cuts(1 99)

* ===================================================
* 机制变量 3：政府补助数据
* ===================================================
merge 1:1 stkcd year using "data/", nogen keep(1 3)

replace 政府补助 = 0 if missing(政府补助)
replace 政府补助占总资产比例 = 0 if missing(政府补助占总资产比例)

* 构建机制变量
gen ln_sub = ln(政府补助 + 1)
gen sub_asset = 政府补助占总资产比例

* 计算每年每个行业的政府补助总盘子
bysort ind_id year: egen Ind_Total_Sub = sum(政府补助)
bysort ind_id year: egen Ind_Total_Sub_asset = sum(sub_asset)

* 计算企业份额
gen sub_share = 政府补助 / Ind_Total_Sub
gen sub_share_asset = sub_asset / Ind_Total_Sub_asset

* 统一缩尾处理
winsor2 ln_sub sub_asset, replace cuts(1 99)

local base_vars OverInvest N_Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND

* 只剔除 base_vars 里的缺失值
foreach i in `base_vars' {
    drop if missing(`i')
}

* 设定面板
xtset stkcd year

* ===================================================
* 描述性统计（一键导出为 Word 格式表）
* ===================================================
* 定义机制变量的宏
local mech_vars ln_dte ln_dtu ln_total_patents ld hd ln_high_low ln_sub sub_asset

* 1. 导出 Panel A：基准变量
sum `base_vars'


* 2. 导出 Panel B：机制变量
sum `mech_vars'




/* ===================================================
   基准回归
   =================================================== */

clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 (核心修复！把所有变量都加上)
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'


***可行***

reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)

reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year) vce(cluster stkcd)

reghdfe OverInvest N_Integration, absorb(stkcd year) vce(cluster stkcd)






* 生成年份虚拟变量与 Integration 的交互项
* 看看是不是只有 2023 是负显著的，其他年份都不显著

reghdfe OverInvest c.N_Integration#i.year Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd ind_id)
reghdfe OverInvest c.N_Integration#i.year Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)

	
/* ===================================================
   查看指标排名前 20 的"头部企业"
   =================================================== */

* 0. 确保数据在内存中 (如果不在，请先加载合并后的数据)
* use "data/合并后的最终数据.dta", clear

* ----------------------------------------------------
* 1. 查看"过度投资"最严重的前 20 名 (OverInvest)
* ----------------------------------------------------
display ">>> 过度投资 (OverInvest) 前 20 名名单 <<<"

* 按过度投资程度从大到小排序 (降序)
gsort -OverInvest

* 列出前20名
* 包含：代码、年份、过度投资程度、企业规模、总资产收益率
list stkcd year ShortName OverInvest Size ROA in 1/20, sep(5)

* ----------------------------------------------------
* 2. 查看"数字创新网络融入度"最高的前 20 名 (Integration)
* ----------------------------------------------------
display ">>> 数字创新网络融入度 (N_Integration) 前 20 名名单 <<<"

* 按融入度从大到小排序 (降序)
gsort -Integration

* 列出前20名
list stkcd year ShortName N_Integration in 1/20, sep(5)
	
* ----------------------------------------------------
* 3. 查看"page_rank"最高的前 20 名 (page_rank)
* ----------------------------------------------------
display ">>> pagerank (page_rank) 前 20 名名单 <<<"

* 按融入度从大到小排序 (降序)
gsort -page_rank

* 列出前20名
list stkcd year ShortName page_rank in 1/20, sep(5)

* ----------------------------------------------------
* 4. 查看"page_rank"最高的前 20 名 (w_out_degree)
* ----------------------------------------------------
display ">>> w_out_degree (w_out_degree) 前 20 名名单 <<<"

* 按融入度从大到小排序 (降序)
gsort -w_out_degree

* 列出前20名
list stkcd year ShortName w_out_degree in 1/20, sep(5)

* ----------------------------------------------------
* 5. 查看"page_rank"最高的前 20 名 (w_in_degree)
* ----------------------------------------------------
display ">>> w_in_degree (w_in_degree) 前 20 名名单 <<<"

* 按融入度从大到小排序 (降序)
gsort -w_in_degree

* 列出前20名
list stkcd year ShortName N_Integration in 1/20, sep(5)

* ----------------------------------------------------
* 6. 查看"closeness"最高的前 20 名 (closeness)
* ----------------------------------------------------
display ">>> closeness (closeness) 前 20 名名单 <<<"

* 按融入度从大到小排序 (降序)
gsort -closeness

* 列出前20名
list stkcd year ShortName closeness in 1/20, sep(5)

* ----------------------------------------------------
* 7. 查看"page_rank"最高的前 20 名 (N_Integration)
* ----------------------------------------------------
display ">>> N_Integration (N_Integration) 前 20 名名单 <<<"

* 按融入度从大到小排序 (降序)
gsort -w_out_degree

* 列出前20名
list stkcd year ShortName N_Integration in 1/20, sep(5)

	
	

* 方法：Absorb 个体，Control 年份，在控制了企业个体特征（Fixed Effects）和年份宏观冲击后，数字网络融入度（Integration）与过度投资（OverInvest）之间存在显著的负相关关系。
* 注意：这里要把 year 写成 i.year
. binscatter OverInvest N_Integration, absorb(stkcd) controls(i.year) line(qfit)

* 1. 提取残差 (如果还没做)
reghdfe OverInvest, absorb(stkcd year) residuals(r_y)
reghdfe N_Integration, absorb(stkcd year) residuals(r_x)

* 2. 对残差进行缩尾 (去掉极端的 1% 或 5%)
winsor2 r_y, replace cuts(1 99)
winsor2 r_x, replace cuts(1 99)

* 3. 再画一次 binscatter
binscatter r_y r_x, line(qfit) nquantiles(20)







/* ===================================================
   机制分析A：创新质量提升
   =================================================== */

clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)


* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'


merge 1:1 stkcd year using "data/", nogen keep(1 3) 


replace ln_total_patents = 0 if missing(ln_total_patents)
replace ln_dte = 0 if missing(ln_dte)
replace ln_dtu = 0 if missing(ln_dtu)

replace dte_count = 0 if missing(dte_count)
replace dtu_count = 0 if missing(dtu_count)
replace total_patents = 0 if missing(total_patents)


* 剔除缺失值
foreach i in ln_dte ln_dtu ln_total_patents{
    drop if `i'==.
}

reghdfe ln_dte N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd) 
reghdfe ln_dtu N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd) 
reghdfe ln_total_patents N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd) 





/* ===================================================
   机制分析B：要素配置结构优化（人力资本结构升级）
   =================================================== */

* 1. 数据合并与清洗 (保持你的原有逻辑)
clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 (核心修复！把所有变量都加上)
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'

* 合并人力资本数据
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* ---------------------------------------------------
* 2. 核心基数计算
* 高学历（本科及以上）；低学历（专科及以下）
* ---------------------------------------------------
* 1. 基础加总
egen high_edu_count = rowtotal(博士人数 硕士人数 本科人数)
egen low_edu_count = rowtotal(高中及以下人数 专科人数)

* 2. 数据清洗
* 剔除缺乏基础创新吸收能力（0个本科生）或数据披露异常（0个底层员工）的样本
drop if high_edu_count == 0
drop if low_edu_count == 0

* 3. 计算比值对数（因为已经剔除了0，直接相除取对数，无需再加1掩盖）
gen ln_high_low = ln( high_edu_count / low_edu_count )

* 4. 绝对规模对数
gen hd = ln(high_edu_count)
gen ld = ln(low_edu_count)

* 5. 缩尾处理
winsor2 hd ld ln_high_low, replace cuts(1 99)

* 6. 核心回归（高维固定效应）
* 检验一：低端要素动态 
reghdfe ld N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd) 

* 检验二：高端要素引进 
reghdfe hd N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd) 

* 检验三：人力资本结构升级（你的核心绝杀）
reghdfe ln_high_low N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)






/* ===================================================
   机制分析C：政策
   =================================================== */

clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 (核心修复！把所有变量都加上)
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'

*合并政府补助数据
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 将政府补助的缺失值真实还原为0
replace 政府补助 = 0 if missing(政府补助)
replace 政府补助占总资产比例 = 0 if missing(政府补助占总资产比例)

*构建机制变量

*(1) 绝对规模：政府补助加1取自然对数
gen ln_sub = ln(政府补助 + 1)

*(2) 相对规模：政府补助占总资产比例
gen sub_asset = 政府补助占总资产比例

*(3) 核心竞争力(你的创新构想)：该企业获取的补助占全行业的份额

*计算每年每个行业的政府补助总盘子
bysort ind_id year: egen Ind_Total_Sub = sum(政府补助)

bysort ind_id year: egen Ind_Total_Sub_asset = sum(sub_asset)

*计算企业份额
gen sub_share = 政府补助 / Ind_Total_Sub

gen sub_share_asset = sub_asset / Ind_Total_Sub_asset

*统一缩尾处理
winsor2 ln_sub sub_asset, replace cuts(1 99)
 
*剔除缺失值
foreach i in ln_sub sub_asset{
    drop if `i'==.
}

*执行核心机制回归

*回归 1：补助绝对规模 (ln_sub)
reghdfe ln_sub N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)
*回归 2：补助占资产比 (sub_asset)
reghdfe sub_asset N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)
  
 
 
 
 
 
 
 
 
 
   
/* ============================================================================
   异质性分析：产权性质 × 行业技术密集度 × 地理区位
   ============================================================================ */

clear all
set more off

* =============================================================
* 1. 导入数据与基础处理
* =============================================================
use "data/Final_Regression_Dataset.dta", clear

* 合并过度投资数据
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 锁定时间窗口
keep if year >= 2012 & year <= 2023

* 统一行业编码
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3)
capture drop ind_id
encode ind3, gen(ind_id)

* 剔除缺失值
local base_vars OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND
foreach i in `base_vars' {
    drop if missing(`i')
}

* 设定面板
xtset stkcd year

* =============================================================
* 2. 构建异质性分组变量
* =============================================================

* --- 2.1 产权性质：国有 vs 民营 ---
* IsStateAssetsBack: 1=有国有资产背景(国有), 0=无(民营)
capture drop SOE
gen SOE = (IsForInvestBack == 1) // 注意：依据你之前的截图，国资背景变量名可能是 IsForInvestBack
label var SOE "国有企业"
label define soe_lbl 0 "民营企业" 1 "国有企业"
label values SOE soe_lbl
tab SOE

* --- 2.2 行业技术密集度：高技术 vs 非高技术 ---
* 基于证监会行业代码前两位/三位判定
capture drop high_tech
gen high_tech = 0
replace high_tech = 1 if inlist(substr(Indcd1, 1, 3), "C27", "C37", "C39", "C40")
replace high_tech = 1 if inlist(substr(Indcd1, 1, 3), "I63", "I64", "I65")
label var high_tech "高技术行业"
label define tech_lbl 0 "非高技术" 1 "高技术"
label values high_tech tech_lbl
tab high_tech

* --- 2.3 地理区位：东部沿海 vs 中西部 ---
* 生成高维固定效应需要的城市与省份 ID
drop if missing(PROVINCE)
capture encode PROVINCE, gen(province_id)

drop if missing(CITY)
capture encode CITY, gen(city_id)

capture drop east_coast
gen east_coast = 0

* 【核心修复区】：分两批使用 inlist，完美避开 expression too long 和引号报错
replace east_coast = 1 if inlist(PROVINCE, "北京市", "天津市", "河北省", "辽宁省", "上海市", "江苏省")
replace east_coast = 1 if inlist(PROVINCE, "浙江省", "福建省", "山东省", "广东省", "海南省")

label var east_coast "东部沿海地区"
label define region_lbl 0 "中西部地区" 1 "东部沿海地区"
label values east_coast region_lbl
tab east_coast

* =============================================================
* 3. 定义全局回归设定
* =============================================================
local Y "OverInvest"
local X "N_Integration"
local controls "Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND"
local absorb "absorb(stkcd year ind_id#year)"
local vce "vce(cluster stkcd)"

* =============================================================
* 4. 异质性回归
* =============================================================

* --- 4.1 产权性质异质性 ---
di _n "=== 产权性质异质性 ==="

reghdfe `Y' `X' `controls' if SOE == 1, `absorb' `vce'
est store m_soe

reghdfe `Y' `X' `controls' if SOE == 0, `absorb' `vce'
est store m_private


* --- 4.2 行业技术密集度异质性 ---
di _n "=== 行业技术密集度异质性 ==="

reghdfe `Y' `X' `controls' if high_tech == 1, `absorb' `vce'
est store m_hightech

reghdfe `Y' `X' `controls' if high_tech == 0, `absorb' `vce'
est store m_lowtech


* --- 4.3 地理区位异质性 ---
di _n "=== 地理区位异质性 ==="

reghdfe `Y' `X' `controls' if east_coast == 1, `absorb' `vce'
est store m_east

reghdfe `Y' `X' `controls' if east_coast == 0, `absorb' `vce'
est store m_west


	




/* ===================================================
   内生性解决方案 A：构建滞后期
   =================================================== */

clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'
    
   
xtset stkcd year
sort stkcd year
gen L_N_Integration = L.N_Integration
label var L_N_Integration "滞后一期的创新网络融入"

gen L2_N_Integration = L2.N_Integration
label var L2_N_Integration "滞后二期的创新网络融入"

gen L3_N_Integration = L3.N_Integration
label var L3_N_Integration "滞后三期的创新网络融入"

gen L4_N_Integration = L4.N_Integration
label var L4_N_Integration "滞后四期的创新网络融入"


reghdfe OverInvest L_N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year) vce(cluster stkcd)
reghdfe OverInvest L2_N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year) vce(cluster stkcd)
reghdfe OverInvest L3_N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year) vce(cluster stkcd)
reghdfe OverInvest L4_N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year) vce(cluster stkcd)







/* ===================================================
   内生性解决方案 B：构建工具变量（用Intergration代替N_Intergration)
   构建 Bartik IV ：基于"城市"层面
   逻辑：利用 300+ 地级市的差异，最大化 IV 的变异度
   =================================================== */

clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 (核心修复！把所有变量都加上)
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'
 
* 0. 准备工作
* 您的数据中"所属城市"是字符型，需要先编码为数值
* 如果有缺失值或空值，先清理一下
drop if missing(PROVINCE)
capture encode PROVINCE, gen(province_id)

drop if missing(CITY)
capture encode CITY, gen(city_id)

* ----------------------------------------------------
* 第一步：构建初始份额 Share (2012年各城市的平均数字化水平)
* ----------------------------------------------------
* 逻辑：2012年这个城市的数字化基础越好，后续受到的浪潮冲击越大
* 注意：这里用 city_id 分组
bysort city_id: egen temp_share_city = mean(Integration) if year == 2012

* 广播给该城市的所有年份
bysort city_id: egen Share_City_Base = max(temp_share_city)
drop temp_share_city

* 清洗：如果某城市在2012年没有上市企业数据，则无法构建 IV
* (这一步可能会损失一些样本，但留下的都是高质量样本)
drop if missing(Share_City_Base)

* ----------------------------------------------------
* 第二步：构建移动 Shift (行业层面的年度趋势)
* ----------------------------------------------------
* 逻辑：该行业在全国的平均增长趋势 (技术浪潮)
* 这与之前一样，反映宏观技术冲击
capture drop Shift_Ind_Time
bysort ind_id year: egen Shift_Ind_Time = mean(Integration)

* ----------------------------------------------------
* 第三步：生成城市级 Bartik 工具变量
* ----------------------------------------------------
gen IV_Bartik_City = Share_City_Base * Shift_Ind_Time
label variable IV_Bartik_City "Bartik IV: 2012城市份额 × 行业年度趋势"


* 检查工具变量在组内和组间的变异
egen mean_IV = mean(IV_Bartik_City), by(stkcd) // 计算每个公司的均值（组间部分）
gen dev_IV = IV_Bartik_City - mean_IV // 计算每个公司的时间离差（组内部分）

* 分别看组间和组内部分的方差（计算组间变异占总变异的比例：(mean_IV Std. dev.)^2 / [(mean_IV Std. dev.)^2 + (dev_IV Std. dev.)^2] ≈ 82.1%。这意味着超过82%的工具变量变异来自横截面差异，故不使用"企业个体固定效应（Firm FE）"，而改用"行业固定效应（Industry FE）"，因为绝大多数企业是不跨城市搬迁的，个体固定效应会瞬间把这 82.1% 的核心变异全部吸干（抹平））
sum mean_IV dev_IV

* ----------------------------------------------------
* 第四步：运行 2SLS 回 
* ----------------------------------------------------

ivreghdfe OverInvest Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND (N_Integration = IV_Bartik_City), absorb(ind_id year) cluster(stkcd) first	






/* ===================================================
   内生性解决方案 C：PSM (倾向得分匹配)
   逻辑：匹配"处理前"特征，防止样本选择偏差
   =================================================== */
   
clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 3. 终极剔除缺失值
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if missing(`i')
}   
   
* 4. 准备工作：生成滞后项
xtset stkcd year
foreach var in Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND{
    capture drop l_`var'
    gen l_`var' = L.`var'
}

* 5. 剔除生成滞后项产生的缺失值，保证匹配池完美对齐
foreach var in Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND{
    drop if missing(l_`var')
} 

* 6. 锁定时间窗口
keep if year >= 2012  
   
* 7. 定义处理组
capture drop High_Dig_n
bysort year: egen median_int = median(N_Integration)
gen High_Dig_n = (N_Integration > median_int)
drop median_int

* 8. 进行 PSM 匹配
set seed 12345 
psmatch2 High_Dig_n l_Size l_Age l_Cashflow l_RDSpendSumRatio l_Lev l_Growth l_ADM l_Board l_IND, ///
    out(OverInvest) logit neighbor(4) caliper(0.05) common

* 9. 检验平衡性 
pstest l_Size l_Age l_Cashflow l_RDSpendSumRatio l_Lev l_Growth l_ADM l_Board l_IND, both graph

* 10. 回归：
reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND ///
    if _weight != ., absorb(stkcd year) vce(cluster stkcd)

/* 结果解读：
   关注 N_Integration 的系数是否依然显著为负。
   如果是，说明剔除样本选择偏差后，结论稳健。
*/



	
	  	
	
/* ===================================================
   稳健性解决方案 A：更换核心解释变量
   =================================================== */	

clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 (核心修复！把所有变量都加上)
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars' 
   

   
reghdfe OverInvest Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year) vce(cluster stkcd)	

	


	
/* ===================================================
   稳健性解决方案 B：更换Biddle 模型
   =================================================== */
  
clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 (核心修复！把所有变量都加上)
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'  
  
*** 2. 生成 Biddle 模型所需的 INV 变量 ***
* 定义：新增投资 / 年初总资产 [cite: 1177]
xtset stkcd year
gen INV_Biddle = New_Invest_Amt / L.A100000

*** 3. 运行 Biddle (2009) 模型回归 ***
* 模型：INV = b0 + b1 * Growth + e [cite: 1177]
* 控制 行业-年份 联合固定效应来吸收分组回归的效果
* 注意：l_Growth 是滞后一期的营业收入增长率
capture drop resid_biddle
reghdfe INV_Biddle l_Growth, absorb(industry_id#year) residuals(resid_biddle)

* 方式：区分过度投资 (只取正值)
gen Over_Biddle = 0
replace Over_Biddle = resid_biddle if resid_biddle > 0 & resid_biddle != .

*** 5. 缩尾处理 ***
winsor2 Over_Biddle, replace cuts(1 99)

* 剔除缺失值
foreach i in Over_Biddle{
    drop if `i'==.
}


*** 6. 最终回归检验 ***
* 看看创新融入度是否降低了投资非效率？
reghdfe Over_Biddle N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year) vce(cluster stkcd)



	
/* ===================================================
   稳健性解决方案 C：安慰剂检验
   =================================================== */
clear all
set more off

* 1. 导入数据
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定时间窗口
keep if year >= 2012 

* 3. 统一行业编码 (避免命名冲突)
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 4. 终极剔除缺失值 (核心修复！把所有变量都加上)
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if `i'==.
}

* 5. 检查最终进入回归的样本结构
xtset stkcd year
sum `base_vars'
* ----------------------------------------------------
* 2. 真实回归 & 锁定样本 (【修改点】：去掉了 L. )
* ----------------------------------------------------
xtset stkcd year
reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, ///
    absorb(stkcd year ind_id#year) vce(cluster stkcd)

* 自动提取当期的真实系数
local true_coef = _b[N_Integration]
di "======================================="
di ">>> 请记下你的真实当期系数: `true_coef'"
di "======================================="

keep if e(sample) // 锁定回归样本

* 3. 准备容器
capture postclose buffer
postfile buffer beta_fake using "placebo_simulation.dta", replace

* 4. 循环 500 次
set seed 12345678 
di ">>> 开始模拟..."

forvalues i = 1/500 {
    if mod(`i', 50) == 0 di "Iter: `i'"
    
    preserve
    
    * 【最简单的打乱逻辑】
    * 提取 N_Integration 到临时文件
    keep year N_Integration
    gen r = runiform()
    sort year r // 打乱
    rename N_Integration Fake_Integration
    gen obs_id = _n // 生成乱序后的ID
    save "temp_fake_x.dta", replace
    
    restore // 恢复主数据
    preserve
    
    * 合并假变量
    * 主数据也生成一个对应的 ID (按年份排序)
    sort year
    gen obs_id = _n
    merge 1:1 obs_id using "temp_fake_x.dta", nogen keep(1 3)
    
    * 此时 Fake_Integration 就是完全随机匹配的了！
    * 必须重新排序回面板
    sort stkcd year
    xtset stkcd year
    
    * 跑回归 (【修改点】：去掉了 L. , 使用当期的 Fake_Integration)
    capture reghdfe OverInvest Fake_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, ///
        absorb(stkcd year ind_id#year)
    
    if _rc == 0 {
        post buffer (_b[Fake_Integration])
    }
    else {
        post buffer (.)
    }
    
    restore
}
postclose buffer

/* ===================================================
   5. 最终绘图
   =================================================== */
use "placebo_simulation.dta", clear

* 【重要操作】：手动填入刚才屏幕打印出来的"真实当期系数"
* 假设你刚才跑出来的真实当期系数依然是 -0.088，如果变了请修改这里！
local true_coef = -0.088 

* 绘图：强制扩展 X 轴的显示范围，确保把真实系数包进去
* (如果你的真系数是 -0.08，那么 range(-0.12 0.05) 是合适的；如果真系数不同，请微调 range)
twoway (kdensity beta_fake, bwidth(0.008) color(gs12) recast(area)), /// 
       xline(`true_coef', lcolor(red) lwidth(thick) lpattern(dash)) ///
       xscale(range(-0.12 0.05)) ///  
       xlabel(-0.12 -0.08 -0.04 0 0.04) /// 
       title("Placebo Test (500 Simulations)") ///
       xtitle("Estimated Coefficients") ///
       ytitle("Density") ///
       legend(off) ///
       scheme(s1mono) ///
       note("Note: The red dashed line indicates the true baseline coefficient (-0.088).")

* 导出高分辨率图片
graph export "Placebo_Test_Final.png", replace width(2000)




/* ===================================================
   稳健性解决方案 D：高维固定效应
   =================================================== */

* 1. 重新导入干净数据 (极其重要，洗掉安慰剂的残余！)
clear all
set more off
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定窗口与行业
keep if year >= 2012 
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 3. 终极剔除
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if missing(`i')
}

* 4. 生成高维固定效应需要的城市与省份 ID（否则会报错）
drop if missing(PROVINCE)
capture encode PROVINCE, gen(province_id)

drop if missing(CITY)
capture encode CITY, gen(city_id)

* 5. 设定面板后开始你的回归
xtset stkcd year

reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)

reghdfe OverInvest N_Integration, absorb(stkcd year ind_id#year) vce(cluster stkcd)


reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year city_id#year) vce(cluster stkcd)

reghdfe OverInvest N_Integration, absorb(stkcd year city_id#year) vce(cluster stkcd)


reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year province_id#year) vce(cluster stkcd)

reghdfe OverInvest N_Integration, absorb(stkcd year province_id#year) vce(cluster stkcd)


asdoc reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)

asdoc reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year city_id#year) vce(cluster stkcd)

asdoc reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year province_id#year) vce(cluster stkcd)



reghdfe OverInvest Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year ind_id#year) vce(cluster stkcd)
reghdfe OverInvest Integration, absorb(stkcd year ind_id#year) vce(cluster stkcd)


reghdfe OverInvest Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year city_id#year) vce(cluster stkcd)
reghdfe OverInvest Integration, absorb(stkcd year city_id#year) vce(cluster stkcd)


reghdfe OverInvest Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND, absorb(stkcd year province_id#year) vce(cluster stkcd)
reghdfe OverInvest Integration, absorb(stkcd year province_id#year) vce(cluster stkcd)














* ==========================================================
* 异质性分析：企业属性与外部制度环境的调节效应
* 核心变量：OverInvest (Y), N_Integration (X)
* 控制变量：Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND
* ==========================================================

* 1. 重新导入干净数据 (极其重要，洗掉安慰剂的残余！)
clear all
set more off
use "data/Final_Regression_Dataset.dta", clear
merge 1:1 stkcd year using "data/", nogen keep(1 3)

* 2. 锁定窗口与行业
keep if year >= 2012 
capture drop ind3
gen ind3 = substr(Indcd1, 1, 3) 
capture drop ind_id
encode ind3, gen(ind_id) 

* 3. 终极剔除
local base_vars OverInvest N_Integration Integration Size Age Lev Cashflow RDSpendSumRatio Growth ADM Board IND
foreach i in `base_vars' {
    drop if missing(`i')
}

* ----------------------------------------------------------
* 1. 所有制异质性 (国资背景企业 vs 无国资背景企业)
* 使用您的变量：IsForInvestBack (1=有国资背景，0=无国资背景)
* ----------------------------------------------------------
* 国资背景组
eststo SOE1: reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND ///
    if IsForInvestBack == 1, absorb(stkcd year ind_id#year) vce(cluster stkcd)
    
* 无国资背景组
eststo SOE0: reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND ///
    if IsForInvestBack == 0, absorb(stkcd year ind_id#year) vce(cluster stkcd)


* ----------------------------------------------------------
* 2. 地区异质性 (东部地区 vs 中西部地区)
* 注意：需要您先弄清楚 province_id 里面哪个数字代表哪个省份
* ----------------------------------------------------------
* 假设您查明后，生成了代表东部省份的虚拟变量 EastRegion
* （以下为举例，假设 1,2,3,4 是北上广深苏浙等东部省份代码，请根据实际替换）
gen EastRegion = 0
replace EastRegion = 1 if inlist(province_id, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)

* 东部地区组
eststo East1: reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND ///
    if EastRegion == 1, absorb(Stkcd Year ind_id#Year) vce(cluster Stkcd)

* 中西部地区组
eststo East0: reghdfe OverInvest N_Integration Size Age Cashflow RDSpendSumRatio Lev Growth ADM Board IND ///
    if EastRegion == 0, absorb(Stkcd Year ind_id#Year) vce(cluster Stkcd)


* ==========================================================
* 3. 导出结果到 Word
* ==========================================================
esttab SOE1 SOE0 East1 East0 using "Table_4_13_Heterogeneity.rtf", replace ///
    b(%3.4f) t(%3.4f) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("国资背景" "无国资背景" "东部地区" "中西部地区") ///
    keep(N_Integration) /// 
    scalars(N r2_a) /// 
    addnotes("注：括号内为聚类到企业层面的稳健t值，控制变量均已加入，控制了企业、年份及行业-年份固定效应。") ///
    compress nogap
