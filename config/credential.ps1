# ──── bsk.exe 报表预热自动化 — 账号凭据 ────
# 提交时可保留测试环境凭据（test 环境），生产环境凭据设为占位符
# 部署到生产机器时修改 prod 对应的账号密码即可

$SCRIPT:AccountUser = @{
    "test" = "testyure"
    "prod" = "your_prod_account"
}

$SCRIPT:AccountPass = @{
    "test" = "Fc123456"
    "prod" = "your_prod_password"
}
