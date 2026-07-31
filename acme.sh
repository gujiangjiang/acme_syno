#!/bin/bash

# ===============================================================
# acme.sh 群晖自动证书申请与部署脚本 (主执行逻辑)
# ===============================================================
#
# 【群晖任务计划执行指南】
# 请在群晖 DSM 依次点击：“控制面板” -> “任务计划” -> “新增” -> “计划的任务” -> “用户定义的脚本”。
# 建议将任务的运行频率设置为：每月运行一次（例如每月 1 日凌晨 2 点）。
#
#  【用法一：单域名默认执行】 (脚本会自动去 config 文件夹下找 config.conf)
# bash /volume1/docker/acme.sh/auto/acme.sh >>/volume1/docker/acme.sh/auto/acmelog.txt 2>&1
#
#  【用法二：多域名复用执行】 (明确指定 config 文件夹下的各个配置文件)
# 域名 A:
# bash /volume1/docker/acme.sh/auto/acme.sh /volume1/docker/acme.sh/auto/config/config_aaa.conf >>/volume1/docker/acme.sh/auto/acmelog.txt 2>&1
# 域名 B:
# bash /volume1/docker/acme.sh/auto/acme.sh /volume1/docker/acme.sh/auto/config/config_bbb.conf >>/volume1/docker/acme.sh/auto/acmelog.txt 2>&1
# ===============================================================

# ===============================================================
# 1. 动态加载外部配置文件 (支持参数传入、config文件夹及智能回退)
# ===============================================================

# 获取当前脚本所在的绝对路径
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# 初始化一个回退标记，用于后续输出日志
FALLBACK_TRIGGERED=false

# --- 1.1 确定配置文件的路径 ---
if [ -n "$1" ]; then
    # 场景 A: 明确传入了参数，直接使用传入的路径
    CONFIG_FILE="$1"
else
    # 场景 B: 没有传入参数，启动自动寻找机制
    if [ -f "${SCRIPT_DIR}/config/config.conf" ]; then
        # 优先级 1: 寻找 config 文件夹内的配置文件（理想状态）
        CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"
    elif [ -f "${SCRIPT_DIR}/config.conf" ]; then
        # 优先级 2: 触发智能回退，寻找与脚本同目录的配置文件
        CONFIG_FILE="${SCRIPT_DIR}/config.conf"
        FALLBACK_TRIGGERED=true
    else
        # 两个位置都没找到，将其置空以便触发下方的报错机制
        CONFIG_FILE=""
    fi
fi

# --- 1.2 验证并加载配置文件 ---
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "================================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ 成功加载配置: $CONFIG_FILE"
    
    # 如果触发了回退机制，打印一句友好的提示日志
    if [ "$FALLBACK_TRIGGERED" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ 提示: 未在 config 目录找到配置文件，已智能回退加载同目录下的文件。"
    fi
else
    echo "================================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ 致命错误: 无法找到配置文件！"
    echo "请检查以下情况之一："
    echo "1. 若您在计划任务中指定了配置文件路径，请检查该路径是否正确输入。"
    echo "2. 若您使用默认执行，请确保在以下任一位置存在配置文件："
    echo "   - 推荐位置: ${SCRIPT_DIR}/config/config.conf"
    echo "   - 备选位置: ${SCRIPT_DIR}/config.conf"
    exit 1
fi

# ===============================================================
# 2. 智能执行脚本 (自动判断 Issue / Renew)
# ===============================================================

echo "开始处理域名: ${DOMAIN}"
echo "准备执行 acme.sh 脚本..."

# 根据选择的DNS服务商，准备对应的环境变量，使用数组防止空格引发错误
declare -a DNS_ENV_VARS
case $DNS in
"dns_cf")
  echo "使用 Cloudflare (dns_cf) 进行验证。"
  DNS_ENV_VARS=("-e" "CF_Token=${CF_Token}" "-e" "CF_Account_ID=${CF_Account_ID}" "-e" "CF_Zone_ID=${CF_Zone_ID}")
  ;;
"dns_dp")
  echo "使用 腾讯云 DNSPOD (dns_dp) 进行验证。"
  DNS_ENV_VARS=("-e" "DP_Id=${DP_Id}" "-e" "DP_Key=${DP_Key}")
  ;;
"dns_ali")
  echo "使用 阿里云 (dns_ali) 进行验证。"
  DNS_ENV_VARS=("-e" "Ali_Key=${Ali_Key}" "-e" "Ali_Secret=${Ali_Secret}")
  ;;
*)
  echo "❌ 错误: 未知的 DNS 供应商 [${DNS}]。请检查配置文件中的 DNS 设置。"
  exit 1
  ;;
esac

# 动作标记，决定最后是否需要部署到群晖
ACTION_NEEDED="none"

# ★ 核心判断：检查 acme.sh 内部是否已经存在该域名的配置 ★
CHECK_EXIST=$(docker exec acme.sh acme.sh --list | grep "${DOMAIN}")

if [ -z "$CHECK_EXIST" ]; then
    # -----------------------------------------------------------
    # 分支 A：未找到记录 -> 执行首次申请 (Issue)
    # -----------------------------------------------------------
    echo " 检查结果：未检测到 ${DOMAIN} 的证书记录。"
    echo "正在为域名 ${DOMAIN} 申请证书..."
    echo " 准备执行首次申请 (--issue)..."
    
    docker exec "${DNS_ENV_VARS[@]}" acme.sh acme.sh \
      --server "${CERT_SERVER}" \
      --issue -d "${DOMAIN}" -d "*.${DOMAIN}" \
      --dns "${DNS}" \
      --log
      
    if [ $? -eq 0 ]; then
        echo "✅ 全新证书申请成功！"
        ACTION_NEEDED="deploy"
    else
        echo "❌ 证书申请失败，请检查上方日志的报错信息。"
        exit 1
    fi

else
    # -----------------------------------------------------------
    # 分支 B：找到记录 -> 执行续签逻辑 (Renew)
    # -----------------------------------------------------------
    echo " 检查结果：检测到 ${DOMAIN} 已存在证书记录。"
    echo "正在为域名 ${DOMAIN} 检查续签状态..."
    echo " 准备执行续签检查 (--renew)..."
    
    docker exec "${DNS_ENV_VARS[@]}" acme.sh acme.sh \
      --server "${CERT_SERVER}" \
      --renew -d "${DOMAIN}" -d "*.${DOMAIN}" \
      --log
      
    ACME_STATUS=$?
    
    if [ $ACME_STATUS -eq 0 ]; then
        echo "✅ 证书已进入续签期，已成功获取新证书！"
        ACTION_NEEDED="deploy"
    elif [ $ACME_STATUS -eq 2 ]; then
        echo "⏳ 当前证书有效期依然充足（剩余大于30天），acme.sh 自动跳过更新。"
        echo " 本次任务圆满结束，脚本执行完毕，无需进一步操作。"
        echo "================================================="
        exit 0
    else
        echo "❌ 续签遇到错误 (状态码: ${ACME_STATUS})，请检查上面的日志输出。"
        exit 1
    fi
fi

# ===============================================================
# 3. 部署证书到群晖
# ===============================================================

# 检查上一步证书申请是否成功并且需要部署
if [ "$ACTION_NEEDED" == "deploy" ]; then
    echo "证书准备就绪，准备部署到 Synology DSM..."
    
    docker exec \
      -e SYNO_Username="${SYNO_Username}" \
      -e SYNO_Password="${SYNO_Password}" \
      -e SYNO_Hostname="${SYNO_Hostname}" \
      -e SYNO_Scheme="${SYNO_Scheme}" \
      -e SYNO_Port="${SYNO_Port}" \
      -e SYNO_Certificate="${SYNO_Certificate}" \
      -e SYNO_DID="${SYNO_Device_ID}" \
      acme.sh acme.sh --deploy -d "${DOMAIN}" -d "*.${DOMAIN}" --deploy-hook synology_dsm --output-insecure
      
    if [ $? -eq 0 ]; then
        echo " 恭喜！新证书已成功部署并应用到群晖系统！"
    else
        echo "❌ 证书部署到群晖失败，请检查账号密码、Device_ID 等变量是否正确。"
        exit 1
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 脚本运行完毕。"
echo "================================================="