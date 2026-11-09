# 全VMの時刻のずれを自動で判定し、ずれているVMだけ補正する（鍵認証が前提。SSHのパスワード入力なし）
#
# 対象ノード : Windows ホスト（PowerShell）から、NAT のポートフォワード経由で client / server / switch / router / router2
# 実行権限   : 一般ユーザー（VM 側は user アカウント）
# 目的       : 実験の前に、ホストと各 VM の時刻差を測り、しきい値を超えた VM だけ sync-time.sh で補正する
# 状態変更   : 判定は読み取りのみ（VM で date を実行するだけ）。しきい値を超えた VM だけ、sync-time.sh を実行して
#              システム時計を補正する（-CheckOnly のときは補正しない）。ホストの設定は変更しない。
# 前提       : A-1〜A-4 完了（鍵で入れること。ssh-agent に鍵が載っていること）。各 VM が起動していて NAT が有効。
#              補正が必要な VM では sync-time.sh が sudo を使うため、sudo のパスワードを聞かれる（A-5 済みなら不要）。
#              -Parallel は A-5（setup-sudo-chronyc.ps1 apply）済みであること。未実施だと各 VM の補正が失敗する（BatchMode のため待たない）。
# 使い方     : .\sync-all-auto.ps1                       # 5台を判定し、ずれた VM だけ補正
#              .\sync-all-auto.ps1 -CheckOnly            # 判定のみ（補正しない）
#              .\sync-all-auto.ps1 -Only client,router   # 一部
#              .\sync-all-auto.ps1 -ThresholdSec 1       # しきい値（既定 2 秒）
#              .\sync-all-auto.ps1 -Parallel             # ずれた VM の補正を同時に実行（A-5 が前提。パスワード入力なし）
# 判定       : 時刻差 = VM の UTC − ホストの UTC（VM の時刻を読んだ直後に応答を受け取った時刻で比べる）。応答の送り返しの遅延ぶん（実測で 0.1 秒未満）の誤差を含む。
#              しきい値以内なら「補正不要」、超えたら補正して再測定し、補正後も超えていれば【要確認】と表示する。
#              ※ chrony の sync_result: OK は、ホストとの一致を保証しない（sync-time.sh の「限界」を参照）。このスクリプトは
#                ホストの時計と直接比べる点が異なる。
# 安全装置   : 各 VM で「ホスト名が想定と一致するか」を先に確認し、違えば何もしない。
# 記録       : data/time-sync/sync-all-auto-<時刻>.txt（パスワードは記録しない）。

param(
    [string[]]$Only = @(),
    [string]$User = "user",
    [double]$ThresholdSec = 2.0,
    [switch]$CheckOnly,
    [switch]$Parallel
)

# powershell -File で起動すると、-Only a,b,c は1つの文字列として渡される。カンマで分割して配列にする
$Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })

$vms = [ordered]@{ client = 2222; server = 2223; switch = 2224; router = 2225; router2 = 2226 }
$logDir = Join-Path $PSScriptRoot "..\..\data\time-sync"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$outFile = Join-Path $logDir ("sync-all-auto-{0}.txt" -f (Get-Date -Format "yyyyMMddTHHmmss"))
function Log($s) { Write-Host $s; Add-Content -Path $outFile -Value $s -Encoding UTF8 }
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# VM の UTC（秒、小数あり）を取得し、ホストとの差（VM − ホスト、秒）を返す。取得できなければ $null
function Measure-Diff($name, $port) {
    # 二重引用符を使わない（Windows PowerShell 5.1 は外部コマンドの引数内の二重引用符を崩すため）
    $remote = 'test $(hostname -s) = __NAME__ && date -u +%s.%N'.Replace('__NAME__', $name)
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $res = & ssh -o BatchMode=yes -o ConnectTimeout=5 -p $port "${User}@127.0.0.1" $remote
    $code = $LASTEXITCODE
    $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $txt = ("$res").Trim()
    $vm = 0.0
    if ($code -ne 0 -or -not [double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, $inv, [ref]$vm)) {
        Log ("  測定失敗: ssh 終了コード={0}（255=接続・認証の失敗、1=ホスト名の不一致の可能性）" -f $code)
        return $null
    }
    $rtt = $t1 - $t0
    # ssh は認証後にコマンドを実行するため、VM の時刻を読むのは往復の終わり近く。往復の中間時刻と比べると往復の約半分だけ
    # 大きく出る（2026-10-24 の実測: 差が往復の約0.53倍、vm_utc − t1 は約 +0.02 秒）。そのため、応答を受け取った時刻 t1 と比べる。
    $diff = $vm - $t1
    Log ("  vm_utc={0}  往復={1:N3}秒  差(VM−ホスト)={2:N3}秒" -f $txt, $rtt, $diff)
    return $diff
}

Log ("# sync-all-auto.ps1  {0}  しきい値={1}秒  CheckOnly={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"), $ThresholdSec, $CheckOnly.IsPresent)
$summary = @()
$targets = @($vms.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$need = @()   # 補正が必要な VM（名前 → 補正前の差）
$before = @{}
foreach ($name in $targets) {
    $port = $vms[$name]
    Log ""
    Log "=== $name (port $port) ==="
    $d = Measure-Diff $name $port
    if ($null -eq $d) { $summary += ("{0}: 測定できず" -f $name); continue }
    if ([math]::Abs($d) -le $ThresholdSec) { $summary += ("{0}: 補正不要（差 {1:N3} 秒）" -f $name, $d); continue }
    if ($CheckOnly) { $summary += ("{0}: 【ずれあり】差 {1:N3} 秒（-CheckOnly のため補正せず）" -f $name, $d); continue }
    $before[$name] = $d
    $need += $name
}

function Remote-Sync($name) { 'test $(hostname -s) = __NAME__ && ./sync-time.sh'.Replace('__NAME__', $name) }

if ($need.Count -gt 0 -and $Parallel) {
    Log ""
    Log ("## 並列で補正: " + ($need -join ", ") + "（BatchMode。sudo のパスワードは聞かない）")
    $jobs = @{}
    foreach ($name in $need) {
        $jobs[$name] = Start-Job -ArgumentList $vms[$name], $User, (Remote-Sync $name) -ScriptBlock {
            param($port, $user, $remote)
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # ジョブの子プロセスの出力が文字化けするのを防ぐ
            & ssh -o BatchMode=yes -p $port "${user}@127.0.0.1" $remote 2>&1 | ForEach-Object { "$_" }
            "__exit__:$LASTEXITCODE"
        }
    }
    Wait-Job -Job @($jobs.Values) | Out-Null
    foreach ($name in $need) {
        Log ""
        Log "=== $name : 補正の出力 ==="
        Receive-Job -Job $jobs[$name] | ForEach-Object { Log ("  " + $_) }
        Remove-Job -Job $jobs[$name]
    }
} elseif ($need.Count -gt 0) {
    foreach ($name in $need) {
        Log ""
        Log ("=== {0} : しきい値を超えています。sync-time.sh を実行します（sudo のパスワードを聞かれます。A-5 済みなら聞かれません）" -f $name)
        & ssh -t -p $vms[$name] "${User}@127.0.0.1" (Remote-Sync $name)
        Log ("  sync-time.sh 終了コード: {0}（0=同期確認、3=同期を確認できず）" -f $LASTEXITCODE)
    }
}

foreach ($name in $need) {
    Log ""
    Log "=== $name : 補正後の再測定 ==="
    $d2 = Measure-Diff $name $vms[$name]
    if ($null -eq $d2) { $summary += ("{0}: 補正後に測定できず【要確認】" -f $name) }
    elseif ([math]::Abs($d2) -le $ThresholdSec) { $summary += ("{0}: 補正した（差 {1:N3} → {2:N3} 秒）" -f $name, $before[$name], $d2) }
    else { $summary += ("{0}: 【要確認】補正後も差 {1:N3} 秒" -f $name, $d2) }
}

Log ""
Log "## まとめ"
if ($targets.Count -eq 0) { Log ("警告: 対象のVMがありません。-Only の名前を確認してください（利用可能: " + ($vms.Keys -join ", ") + "）。") }
$summary | ForEach-Object { Log ("  " + $_) }
Log "記録: $outFile"
