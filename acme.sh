#!/bin/bash

# ===============================================================
# 基础配置
# ===============================================================

# 你的域名
DOMAIN=''

# 证书供应商 (例如: letsencrypt, buypass, zerossl)
CERT_SERVER='letsencrypt'

# DNS 供应商:
# dns_cf (Cloudflare)
# dns_dp (腾讯云 DNSPOD)
# dns_ali (阿里云)
# 更多请查阅: https://github.com/acmesh-official/acme.sh/wiki/dnsapi
DNS=""


# ===============================================================
# DNS API 凭证
# 根据上面选择的 DNS 供应商，填写对应的凭证
# ===============================================================

# --- Cloudflare (新版 API Token) ---
# 请确保 Token 拥有 Zone.Zone 和 Zone.DNS 的编辑权限
CF_Token=""
CF_Account_ID=""
CF_Zone_ID=""   # 可选，但建议填写以提高验证效率

# --- 腾讯云 DNSPOD.CN ---
DP_Id=''
DP_Key=''

# --- 阿里云 ---
Ali_Key=''
Ali_Secret=''


# ===============================================================
# 群晖 (Synology) 部署配置
# ===============================================================

# 群晖账号密码
SYNO_Username=''
SYNO_Password=''

# 如果开启了双重验证(2FA)，请在浏览器登录DSM时选中“记住此设备”，
# 然后从浏览器 Cookie 中获取 'id' 的值填入下方
SYNO_Device_ID=''

# 以下群晖连接配置，若非特殊情况请勿更改
SYNO_Hostname=""
SYNO_Scheme=""
SYNO_Port=""

# 要更新的证书名称。
# 使用空字符串("")代表替代DSM中的“默认证书”，这是最常见的用法。
SYNO_Certificate=''


# ===============================================================
# 执行脚本 (无需修改以下内容)
# ===============================================================

echo "准备执行 acme.sh 脚本..."

# 1. 根据选择的DNS服务商，准备对应的环境变量
DNS_ENV_VARS=""
case $DNS in
"dns_cf")
  echo "使用 Cloudflare (dns_cf) 进行验证。"
  DNS_ENV_VARS="-e CF_Token=${CF_Token} -e CF_Account_ID=${CF_Account_ID} -e CF_Zone_ID=${CF_Zone_ID}"
  ;;
"dns_dp")
  echo "使用 腾讯云 DNSPOD (dns_dp) 进行验证。"
  DNS_ENV_VARS="-e DP_Id=${DP_Id} -e DP_Key=${DP_Key}"
  ;;
"dns_ali")
  echo "使用 阿里云 (dns_ali) 进行验证。"
  DNS_ENV_VARS="-e Ali_Key=${Ali_Key} -e Ali_Secret=${Ali_Secret}"
  ;;
*)
  echo "错误: 未知的 DNS 供应商 [${DNS}]。请检查脚本顶部的 DNS 配置。"
  exit 1
  ;;
esac

# 2. 申请或续签证书
echo "正在为域名 ${DOMAIN} 申请/续签证书..."
# shellcheck disable=SC2086
docker exec ${DNS_ENV_VARS} acme.sh acme.sh \
  --server "${CERT_SERVER}" \
  --issue -d "${DOMAIN}" -d "*.${DOMAIN}" \
  --dns "${DNS}" \
  --log

# 3. 部署证书到群晖
# 检查上一步证书申请是否成功
if [ $? -eq 0 ]; then
  echo "证书申请成功，准备部署到 Synology DSM..."
  docker exec \
    -e SYNO_Username="${SYNO_Username}" \
    -e SYNO_Password="${SYNO_Password}" \
    -e SYNO_Device_ID="${SYNO_Device_ID}" \
    -e SYNO_Hostname="${SYNO_Hostname}" \
    -e SYNO_Scheme="${SYNO_Scheme}" \
    -e SYNO_Port="${SYNO_Port}" \
    -e SYNO_Certificate="${SYNO_Certificate}" \
    -e SYNO_DID="${SYNO_Device_ID}" \
    acme.sh acme.sh --deploy -d "${DOMAIN}" -d "*.${DOMAIN}" --deploy-hook synology_dsm --output-insecure
else
  echo "证书申请失败，请检查上面的日志输出。"
  exit 1
fi

echo "脚本执行完毕。"
