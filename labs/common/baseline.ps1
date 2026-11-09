# ベースライン（実験4〜6の構成: client – R1(router) – R2(router2) – server）を、ホストの PowerShell から一括で構築・撤去・確認する
#
# 対象ノード : Windows ホスト（PowerShell）から、NAT のポートフォワード経由で client / server / router / router2
# 実行権限   : 一般ユーザー（VM 側は user アカウント。VM ごとに sudo のパスワードを1回聞かれる）
# 目的       : 再起動後の再構築手順（docs/LAB_RESTART.md §2 の手順4〜6）を1コマンドにする
# 前提       : A-1〜A-4 完了（鍵で入れること。ssh-agent に鍵が載っていること）。4台が起動していて、VirtualBox の NIC の接続先
#              （lan-a / transit / lan-b）が実験4のとおりであること。時刻の確認は別（sync-all-auto.ps1）。
# 動作 (-Action):
#   up     = スクリプトを各 VM に送り（-SkipPush で省略）、各 VM を設定し、client から server への ping で確認する
#              router : route-test.sh router  prepare → fwd on → fw-zone on → route add 192.168.32.0/24 192.168.30.2
#              router2: route-test.sh router2 prepare → fwd on → fw-zone on → route add 192.168.31.0/24 192.168.30.1
#              client : fault-test.sh client base → guard on     server: fault-test.sh server base
#              確認   : client から 192.168.32.20 へ ping（成功し ttl=62 が基準。2026-10-23 に実測）
#   down   = 各 VM の teardown（アドレス・ルート・guard・ip_forward・ゾーンを元に戻し、NetworkManager の管理に戻す）
#   status = 各 VM の show（読み取りのみ）と、client から server への ping
# 状態変更   : up / down は各 VM の実行時の設定を変える（ip・sysctl・nmcli device set・firewall-cmd。永続設定は変えない）。
#              復旧: down、または VM の再起動。影響: ラボの NIC（enp0s8 / enp0s9）のみ。NAT（enp0s3）と SSH は変えない。
# 安全装置   : 各 VM でホスト名が想定と一致しなければ何もしない。実体の各スクリプトも、ホスト名が役割と一致しなければ中止する。
# 記録       : ホスト側 data/baseline/baseline-<動作>-<時刻>.txt（パスワードは記録しない）。
#              VM 側には、各スクリプトが exp4-* / exp5-* の記録を ~/ に残す（transfer.ps1 -Mode pull で回収できる）。

param(
    [Parameter(Mandatory = $true)][ValidateSet("up", "down", "status")][string]$Action,
    [string]$User = "user",
    [switch]$SkipPush
)

$vms = [ordered]@{ router = 2225; router2 = 2226; client = 2222; server = 2223 }
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).ProviderPath
$logDir = Join-Path $root "data\baseline"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$outFile = Join-Path $logDir ("baseline-{0}-{1}.txt" -f $Action, (Get-Date -Format "yyyyMMddTHHmmss"))
function Log($s) { Write-Host $s; Add-Content -Path $outFile -Value $s -Encoding UTF8 }

# 各 VM に置くスクリプト（リポジトリ内のパス）
$scripts = @{
    router  = @("data\exp-static-route\route-test.sh")
    router2 = @("data\exp-static-route\route-test.sh")
    client  = @("data\exp-fault-ip\fault-test.sh")
    server  = @("data\exp-fault-ip\fault-test.sh")
}

# 二重引用符を使わない（Windows PowerShell 5.1 は外部コマンドの引数内の二重引用符を崩すため）。リモートは bash。
$chains = @{
    up = @{
        router  = './route-test.sh router prepare && ./route-test.sh router fwd on && ./route-test.sh router fw-zone on && ./route-test.sh router route add 192.168.32.0/24 192.168.30.2'
        router2 = './route-test.sh router2 prepare && ./route-test.sh router2 fwd on && ./route-test.sh router2 fw-zone on && ./route-test.sh router2 route add 192.168.31.0/24 192.168.30.1'
        client  = './fault-test.sh client base && ./fault-test.sh client guard on'
        server  = './fault-test.sh server base'
    }
    down = @{
        router  = './route-test.sh router teardown'
        router2 = './route-test.sh router2 teardown'
        client  = './fault-test.sh client teardown'
        server  = './fault-test.sh server teardown'
    }
    status = @{
        router  = './route-test.sh router show'
        router2 = './route-test.sh router2 show'
        client  = './fault-test.sh client show'
        server  = './fault-test.sh server show'
    }
}

Log ("# baseline.ps1  action={0}  {1}" -f $Action, (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))
$results = @()

# 1. 送信（up のとき）
if ($Action -eq "up" -and -not $SkipPush) {
    Log ""
    Log "## スクリプトの送信（scp。鍵認証。同名のファイルは上書き）"
    foreach ($name in $vms.Keys) {
        $port = $vms[$name]
        foreach ($rel in $scripts[$name]) {
            $src = Join-Path $root $rel
            & scp -o BatchMode=yes -P $port $src "${User}@127.0.0.1:"
            $c1 = $LASTEXITCODE
            $leaf = Split-Path $rel -Leaf
            $guard = 'test $(hostname -s) = __NAME__ && chmod +x ./__LEAF__ && echo pushed:$(hostname -s):__LEAF__'.Replace('__NAME__', $name).Replace('__LEAF__', $leaf)
            $r = & ssh -o BatchMode=yes -p $port "${User}@127.0.0.1" $guard
            Log ("  {0}: scp={1} chmod/確認={2} {3}" -f $name, $c1, $LASTEXITCODE, ("$r").Trim())
        }
    }
}

# 2. 各 VM の設定（sudo のパスワードは VM ごとに1回。ssh -t の1セッションで一連のコマンドを実行する）
foreach ($name in $vms.Keys) {
    $port = $vms[$name]
    Log ""
    Log "=== $name (port $port) : $Action ==="
    $cmd = 'test $(hostname -s) = __NAME__ && sudo -v && '.Replace('__NAME__', $name) + $chains[$Action][$name]
    if ($Action -eq "status") { $cmd = 'test $(hostname -s) = __NAME__ && '.Replace('__NAME__', $name) + $chains[$Action][$name] }
    & ssh -t -p $port "${User}@127.0.0.1" $cmd
    $code = $LASTEXITCODE
    Log ("  ssh 終了コード: {0}（0 = 一連のコマンドを最後まで実行。個々のコマンドの成否は VM 側の記録 exp4-* / exp5-* を参照）" -f $code)
    $results += ("{0}: 終了コード {1}" -f $name, $code)
}

# 3. 確認: client から server への ping（up / status）
if ($Action -ne "down") {
    Log ""
    Log "## 確認: client から 192.168.32.20 へ ping（基準: 成功、ttl=62）"
    $r = & ssh -o BatchMode=yes -p $vms["client"] "${User}@127.0.0.1" 'test $(hostname -s) = client && ./fault-test.sh client ping 192.168.32.20'
    $txt = ($r -join "`n")
    $r | ForEach-Object { Log ("  " + $_) }
    if ($txt -match "ttl=62") { $verdict = "基準どおり（ttl=62 で応答あり）" }
    elseif ($txt -match "ttl=") { $verdict = "応答あり、ただし ttl が基準と違う（要確認）" }
    else { $verdict = "【応答なし】要確認（各 VM の記録を参照）" }
    Log ("  判定: " + $verdict)
    $results += ("ping client→server: " + $verdict)
}

Log ""
Log "## まとめ"
$results | ForEach-Object { Log ("  " + $_) }
Log "記録: $outFile"
