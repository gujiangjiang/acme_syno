#!/bin/bash

# ===============================================================
# acme.sh 群晖自动证书申请与部署脚本 (主执行逻辑)
# ===============================================================
#
# 【群晖任务计划执行指南】
# 请在群晖 DSM 依次点击：“控制面板” -> “任务计划” -> “新增” -> “计划的任务” -> “用户定义的脚本”。
# 建议将任务的运行频率设置为：每月运行一次（例如每月 1 日凌晨 2 点）。
# 证书有效期 90 天，到期前约 30 天才进入续签窗口，每月检查一次已足够；
# 脚本每次运行都会自动比对并同步部署最新证书到群晖，无需担心遗漏。
#
#  【用法一：单域名默认执行】 (自动寻找 config 目录或同目录下的 config.conf)
# bash /volume1/docker/acme.sh/auto/acme.sh >>/volume1/docker/acme.sh/auto/acmelog.txt 2>&1
#
#  【用法二：多域名复用执行】 (通过后缀指定不同的配置文件，全部输出到同一个日志)
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
    echo "[$(LC_TIME=C date '+%a %b %e %T %Z %Y')] ✅ 成功加载配置: $CONFIG_FILE"
    
    # 如果触发了回退机制，打印一句友好的提示日志
    if [ "$FALLBACK_TRIGGERED" = true ]; then
        echo "[$(LC_TIME=C date '+%a %b %e %T %Z %Y')] ⚠️ 提示: 未在 config 目录找到配置文件，已智能回退加载同目录下的文件。"
    fi
else
    echo "================================================="
    echo "[$(LC_TIME=C date '+%a %b %e %T %Z %Y')] ❌ 致命错误: 无法找到配置文件！"
    echo "请检查以下情况之一："
    echo "1. 若您在计划任务中指定了配置文件路径，请检查该路径是否正确输入。"
    echo "2. 若您使用默认执行，请确保在以下任一位置存在配置文件："
    echo "   - 推荐位置: ${SCRIPT_DIR}/config/config.conf"
    echo "   - 备选位置: ${SCRIPT_DIR}/config.conf"
    exit 1
fi

# ===============================================================
# 2. 运行环境预检 (Pre-flight Check)
# ===============================================================

# 赋默认值：如果配置文件里没写，就默认用 acme.sh
CONTAINER_NAME="${ACME_CONTAINER_NAME:-acme.sh}"

# 部署策略赋默认值：
# smart  = 智能比对，仅当群晖中不存在与容器内一致的证书时才部署 (推荐)
# always = 每次运行都强制执行一次部署
DEPLOY_MODE="${DEPLOY_MODE:-smart}"

# 时区对齐：自动探测群晖系统时区并传递给 acme.sh 容器，
# 让容器内 acme.sh 的日志时间戳与本脚本完全一致（可在 config.conf 中用 TZ 手动指定）。
CONTAINER_TZ="${TZ:-}"
if [ -z "$CONTAINER_TZ" ]; then
    CONTAINER_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
fi
if [ -z "$CONTAINER_TZ" ] && [ -f /etc/TZ ]; then
    CONTAINER_TZ=$(tr -d ' \r\n' < /etc/TZ)
fi

TZ_ENV_VARS=()
if [ -n "$CONTAINER_TZ" ]; then
    TZ_ENV_VARS=("-e" "TZ=${CONTAINER_TZ}")
    echo "🕐 已对齐容器时区: ${CONTAINER_TZ}"
fi

echo "开始处理域名: ${DOMAIN}"
echo "正在预检 Docker 容器状态..."

# 检查目标容器是否处于运行状态
if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null)" != "true" ]; then
    echo "================================================="
    echo "❌ 致命错误: 找不到名为 '${CONTAINER_NAME}' 的容器，或者该容器未处于运行状态！"
    echo "请检查群晖 Container Manager (Docker)，确保该容器已启动。"
    echo "================================================="
    exit 1
fi
echo "✅ 容器 '${CONTAINER_NAME}' 运行正常。"
echo "准备执行证书申请/续签逻辑..."

# 根据选择的DNS服务商，准备对应的环境变量
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

# ===============================================================
# 2.5 证书一致性比对工具函数 (供 smart 模式下"按需部署"判断使用)
# ===============================================================

# 获取容器内当前证书的 SHA256 指纹 (兼容 ECC 与 RSA 两种存放路径)
get_container_cert_fp() {
    docker exec -e "CHECK_DOMAIN=${DOMAIN}" "${CONTAINER_NAME}" sh -c '
        for f in "/acme.sh/${CHECK_DOMAIN}_ecc/${CHECK_DOMAIN}.cer" "/acme.sh/${CHECK_DOMAIN}/${CHECK_DOMAIN}.cer"; do
            [ -f "$f" ] || continue
            openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null
            break
        done
    ' 2>/dev/null | sed "s/^.*=//" | tr -d ":\r" | tr "A-F" "a-f"
}

# 判断给定指纹的证书是否已经存在于群晖系统中
check_cert_deployed() {
    local fp="$1"

    # 指纹读取失败时，直接视为"未部署"，让流程继续部署以保证安全
    if [ -z "$fp" ]; then
        echo "⚠️ 无法读取容器内证书指纹，将直接执行部署以确保安全。"
        return 1
    fi

    # 1. 直接扫描群晖的证书归档目录，查找完全一致的证书
    #    (兼容 DSM 7.2 前后两种路径；任何一个路径可读即可正常比对)
    local base_dir cert_file syno_fp scanned=0
    for base_dir in /usr/syno/etc/certificate/_archive /usr/local/etc/certificate/_archive; do
        [ -d "$base_dir" ] || continue
        scanned=1
        for cert_file in "$base_dir"/*/cert.pem; do
            [ -f "$cert_file" ] || continue
            syno_fp=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null | sed "s/^.*=//" | tr -d ":\r" | tr "A-F" "a-f")
            if [ -n "$syno_fp" ] && [ "$syno_fp" = "$fp" ]; then
                return 0
            fi
        done
    done

    # 群晖证书目录存在且已扫描过但未匹配 -> 判定为未部署 (确保安全)
    if [ "$scanned" = "1" ]; then
        return 1
    fi

    # 2. 兜底机制：群晖证书目录均不存在/不可读时，比对本脚本上次成功部署时留下的记录
    local record_file="${SCRIPT_DIR}/config/.deployed_${DOMAIN}.fingerprint"
    if [ -f "$record_file" ] && [ "$(cat "$record_file" 2>/dev/null | tr -d " \r\n")" = "$fp" ]; then
        return 0
    fi

    return 1
}

# 部署成功后记录本次证书指纹 (作为校验兜底)
save_deployed_fp() {
    local fp="$1"
    if [ -n "$fp" ]; then
        echo "$fp" > "${SCRIPT_DIR}/config/.deployed_${DOMAIN}.fingerprint" 2>/dev/null
    fi
}

# 动作标记，决定最后是否需要部署到群晖
ACTION_NEEDED="none"

# ★ 核心判断：检查 acme.sh 内部是否已经存在该域名的配置 ★
CHECK_EXIST=$(docker exec "${CONTAINER_NAME}" acme.sh --list | grep "${DOMAIN}")
if [ -z "$CHECK_EXIST" ]; then
    # -----------------------------------------------------------
    # 分支 A：未找到记录 -> 执行首次申请 (Issue)
    # -----------------------------------------------------------
    echo " 检查结果：未检测到 ${DOMAIN} 的证书记录。"
    echo "正在为域名 ${DOMAIN} 申请证书..."
    echo " 准备执行首次申请 (--issue)..."
    
    docker exec "${DNS_ENV_VARS[@]}" "${TZ_ENV_VARS[@]}" "${CONTAINER_NAME}" acme.sh \
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
    
    docker exec "${DNS_ENV_VARS[@]}" "${TZ_ENV_VARS[@]}" "${CONTAINER_NAME}" acme.sh \
      --server "${CERT_SERVER}" \
      --renew -d "${DOMAIN}" -d "*.${DOMAIN}" \
      --log
      
    ACME_STATUS=$?
    
    if [ $ACME_STATUS -eq 0 ]; then
        echo "✅ 证书已进入续签期，已成功获取新证书！"
        ACTION_NEEDED="deploy"
    elif [ $ACME_STATUS -eq 2 ]; then
        echo "⏳ 证书尚未到续签期，acme.sh 自动跳过在线续签。"
        if [ "$DEPLOY_MODE" = "always" ]; then
            echo "🔧 部署策略为 always：强制执行一次部署同步。"
            ACTION_NEEDED="deploy"
        else
            echo "🔍 正在校验容器内证书是否已同步部署到群晖 DSM..."
            CONTAINER_CERT_FP=$(get_container_cert_fp)
            if check_cert_deployed "$CONTAINER_CERT_FP"; then
                echo "✅ 校验通过：群晖中已存在与容器内完全一致的证书，无需重复部署。"
            else
                echo "⚠️ 检测到群晖当前证书与容器内证书不一致"
                echo "   （通常是容器后台定时任务已抢先续签，或上次部署失败），自动补发部署..."
                ACTION_NEEDED="deploy"
            fi
        fi
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
    
    # ★ 部署参数标准化 (重要)
    # acme.sh 3.x 的 synology_dsm 钩子读取的是【全大写】变量名 (SYNO_HOSTNAME 等)，
    # 旧版混合大小写变量名 (SYNO_Hostname 等) 会被忽略，导致钩子回退使用域名配置里
    # 持久化的历史旧值（例如早已失效的旧域名，引发 curl error 6 无法解析主机名）。
    # 因此这里：① 显式给地址/协议/端口赋默认值；② 新旧两套变量名同时传递，确保
    # config.conf 中的配置强制生效，并在部署成功后被写回覆盖旧值。
    SYNO_SCHEME="${SYNO_Scheme:-http}"
    SYNO_HOSTNAME="${SYNO_Hostname:-localhost}"
    SYNO_PORT="${SYNO_Port:-5000}"
    echo "🔗 群晖连接地址: ${SYNO_SCHEME}://${SYNO_HOSTNAME}:${SYNO_PORT}"
    
    # 部署前连通性预检 (仅提醒, 不阻断后续部署)
    if docker exec "${CONTAINER_NAME}" curl -s -o /dev/null --connect-timeout 5 "${SYNO_SCHEME}://${SYNO_HOSTNAME}:${SYNO_PORT}/webapi/query.cgi" 2>/dev/null; then
        echo "✅ 群晖 REST API 连通性正常。"
    else
        echo "⚠️ 无法连接到 ${SYNO_SCHEME}://${SYNO_HOSTNAME}:${SYNO_PORT}"
        echo "   若容器使用 bridge 网络，请将 config.conf 中的 SYNO_Hostname 改为群晖局域网 IP (如 192.168.1.10)。"
    fi
    
    # 先记录容器内当前证书的指纹，部署成功后写入本地记录 (校验兜底用)
    CONTAINER_CERT_FP=$(get_container_cert_fp)
    
    docker exec \
      -e SYNO_USERNAME="${SYNO_Username}" \
      -e SYNO_PASSWORD="${SYNO_Password}" \
      -e SYNO_DEVICE_ID="${SYNO_Device_ID}" \
      -e SYNO_HOSTNAME="${SYNO_HOSTNAME}" \
      -e SYNO_SCHEME="${SYNO_SCHEME}" \
      -e SYNO_PORT="${SYNO_PORT}" \
      -e SYNO_CERTIFICATE="${SYNO_Certificate}" \
      -e SYNO_DID="${SYNO_Device_ID}" \
      -e SYNO_Username="${SYNO_Username}" \
      -e SYNO_Password="${SYNO_Password}" \
      -e SYNO_Device_ID="${SYNO_Device_ID}" \
      -e SYNO_Hostname="${SYNO_HOSTNAME}" \
      -e SYNO_Scheme="${SYNO_SCHEME}" \
      -e SYNO_Port="${SYNO_PORT}" \
      -e SYNO_Certificate="${SYNO_Certificate}" \
      "${TZ_ENV_VARS[@]}" \
      "${CONTAINER_NAME}" acme.sh --deploy -d "${DOMAIN}" -d "*.${DOMAIN}" --deploy-hook synology_dsm --output-insecure
      
    if [ $? -eq 0 ]; then
        echo " 恭喜！证书已成功部署并应用到群晖系统！"
        save_deployed_fp "${CONTAINER_CERT_FP}"
    else
        echo "❌ 证书部署到群晖失败，请检查上方日志以及账号密码、Device_ID、群晖地址等配置。"
        exit 1
    fi
fi

# ===============================================================
# 4. 证书状态自检：输出证书真实到期时间 (安全兜底)
#    无论本次是否执行了部署，都会输出当前证书信息供肉眼确认
# ===============================================================

CERT_CHECK=$(docker exec -e "CHECK_DOMAIN=${DOMAIN}" "${CONTAINER_NAME}" sh -c '
  for f in "/acme.sh/${CHECK_DOMAIN}_ecc/${CHECK_DOMAIN}.cer" "/acme.sh/${CHECK_DOMAIN}/${CHECK_DOMAIN}.cer"; do
    [ -f "$f" ] || continue
    openssl x509 -in "$f" -noout -enddate | cut -d= -f2
    if ! openssl x509 -in "$f" -noout -checkend 2592000 >/dev/null 2>&1; then
      echo "__EXPIRING_SOON__"
    fi
    break
  done
' 2>/dev/null)

CERT_ENDDATE=$(echo "$CERT_CHECK" | grep -v "__EXPIRING_SOON__" | head -n 1)
if [ -n "$CERT_ENDDATE" ]; then
    echo "🕒 容器内当前证书到期时间: ${CERT_ENDDATE}"
    echo "   (若本行日期临近或已过期，说明续签流程存在异常，请翻阅上方日志排查)"
fi
if echo "$CERT_CHECK" | grep -q "__EXPIRING_SOON__"; then
    echo "⚠️ 警告: acme.sh 内部证书将在 30 天内到期，续签似乎未生效，请立即排查！"
fi

echo "[$(LC_TIME=C date '+%a %b %e %T %Z %Y')] 脚本运行完毕。"
echo "================================================="