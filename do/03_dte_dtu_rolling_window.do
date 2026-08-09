/* ============================================================================
   🚀 终极融合版：DTE/DTU 滚动窗口测算 (Rolling Window t-5 to t-1)
   ============================================================================ */

clear all
set more off
capture log close

* 1. 准备全量 IPC 数据 (只做一次)
* ---------------------------------------------------------
use "data/digital_citation_patents_mainipc.dta", clear

* 基础清洗
destring 年份_引证原专利, replace force
tostring 股票代码_引证原专利, replace
replace 股票代码_引证原专利 = trim(股票代码_引证原专利)
keep newipzlid_引证原专利 年份_引证原专利 股票代码_引证原专利 IPC_引证原专利

* 去重 (确保引证原专利唯一)
duplicates drop newipzlid_引证原专利, force

* 拆分 IPC
split IPC_引证原专利, parse(";") gen(ipc_single_)
reshape long ipc_single_, i(newipzlid_引证原专利) j(ipc_seq)
drop if ipc_single_ == ""

* 提取小类
gen ipc_study = substr(ipc_single_, 1, 4)
replace ipc_study = strtrim(ipc_study)
drop if ipc_study == ""

* 规范命名
rename newipzlid_引证原专利 patent_id
rename 年份_引证原专利 year
rename 股票代码_引证原专利 stock_code

* 保存为临时文件 (效率更高，不占硬盘)
tempfile master_ipc_data
save `master_ipc_data'


* 2. 循环计算：滚动窗口 (Rolling Window)
* ---------------------------------------------------------
* 初始化结果文件 (tempfile)
clear
tempfile final_results
save `final_results', emptyok

* 设定时间范围
local start_year = 2012
local end_year = 2023 

forval t = `start_year'/`end_year' {
    
    display ">> 正在处理年份 `t' (知识库窗口: " `t'-5 " 到 " `t'-1 ")..."
    
    * A. 构建"过去5年"的知识库
    use `master_ipc_data', clear
    local t_minus_5 = `t' - 5
    local t_minus_1 = `t' - 1
    keep if year >= `t_minus_5' & year <= `t_minus_1'
    keep stock_code ipc_study
    duplicates drop stock_code ipc_study, force
    tempfile knowledge_base
    save `knowledge_base'
    
    * B. 提取"当年"的专利
    use `master_ipc_data', clear
    keep if year == `t'
    
    * C. 匹配与判定
    merge m:1 stock_code ipc_study using `knowledge_base', keep(1 3)
    gen is_new_ipc = (_merge == 1)
    
    * 专利层面判定
    bysort patent_id: egen has_new_domain = max(is_new_ipc)
    duplicates drop patent_id, force
    
    * D. 企业层面汇总 (修正报错)
    gen dte_flag = (has_new_domain == 1)
    gen dtu_flag = (has_new_domain == 0)
    gen one = 1 
    
    collapse (sum) total_patents=one ///
             (sum) dte_count=dte_flag dtu_count=dtu_flag ///
             , by(stock_code)
             
    gen year = `t'
    
    * E. 追加保存
    append using `final_results'
    save `final_results', replace
}

* 3. 后处理与保存
* ---------------------------------------------------------
use `final_results', clear

* 填补缺失值
replace dte_count = 0 if dte_count == .
replace dtu_count = 0 if dtu_count == .

* 计算指标
gen dte_ratio = dte_count / total_patents
gen dtu_ratio = dtu_count / total_patents
gen ln_dte = ln(dte_count + 1)
gen ln_dtu = ln(dtu_count + 1)
gen ln_total_patents = ln(total_patents + 1)

* 缩尾
winsor2 ln_dte, replace cut(1 99)
winsor2 ln_dtu, replace cut(1 99)
winsor2 ln_total_patents, replace cut(1 99)

label var ln_dte "探索式创新(Ln)"
label var ln_dtu "利用式创新(Ln)"
rename stock_code stkcd
destring _all,replace

* 保存最终结果
save "引证企业年份层面_DTE_DTU指标_滚动窗口版.dta", replace

display "✅ 全部完成！已成功计算滚动窗口下的 DTE/DTU 指标。"


