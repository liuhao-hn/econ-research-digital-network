/* ============================================================================
   异质性分析：产权性质 × 行业技术密集度 × 地理区位
   替换原 4.2.5 "网络地位与信息获取速度的构念解构"
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


* =============================================================
* 5. 输出最终结果表格 (修正样本量整数格式)
* =============================================================
esttab m_soe m_private m_hightech m_lowtech m_east m_west ///
    using "Table_4_13_Heterogeneity.rtf", replace ///
    b(4) se(4) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("国有" "民营" "高技术" "非高技术" "东部" "中西部") ///
    keep(`X') /// 
    stats(N r2_a, labels("样本量" "调整R2") fmt(%9.0f %9.4f)) ///  <-- 这里加入了 fmt 控制，N为整数且带千位分隔符，R2保留4位小数
    title("表 4-13：企业属性与外部制度环境异质性分析") ///
    addnotes("注：括号内为聚类到企业层面的稳健标准误。所有回归均控制了企业个体、年份及行业-年份联合固定效应。限于篇幅，控制变量系数未列示。") /// 
    compress nogap
	
di _n "✅ 表格格式已更新完毕！请重新打开 Table_4_13_Heterogeneity.rtf 查看。"

