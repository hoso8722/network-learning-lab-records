# 各VMで、一般ユーザーが chronyc の2つのコマンドだけ、sudo のパスワードなしで実行できるようにする（A-5）
#
# 対象ノード : Windows ホスト（PowerShell）から、NAT のポートフォワード経由で client / server / switch / router / router2
# 実行権限   : 一般ユーザー（VM 側で sudo を使う。apply / remove は sudo のパスワードを聞かれる）
# 目的       : sync-time.sh（sudo chronyc burst 4/4、sudo chronyc makestep）を、パスワード入力なしで実行できるようにする
# 状態変更   : apply  = 各 VM に /etc/sudoers.d/lab-chronyc（<user> ALL=(root) NOPASSWD: <chronyc> burst 4/4, <chronyc> makestep）を作る
#              remove = そのファイルを削除する
#              check  = 変更なし（sudo -n -l <コマンド> で、パスワードなしで実行できるかを調べるだけ。コマンド自体は実行しない）
# 影響       : このユーザーは、パスワードなしで「システム時計を NTP に合わせる」操作ができる。他の sudo は従来どおりパスワードが必要。
# 安全装置   : (1) ホスト名が想定と一致しなければ何もしない。(2) 一時ファイルを visudo -cf で構文検査し、通った場合だけ設置する
#              （構文が壊れた sudoers は sudo 自体を使えなくするため）。(3) ファイルは root:root、権限 440。
# 復旧       : -Action remove。sudo が使えなくなった場合は、VM のコンソールから root でログインし /etc/sudoers.d/lab-chronyc を削除する。
# 使い方     : .\setup-sudo-chronyc.ps1 -Action check [-Only client,server]
#              .\setup-sudo-chronyc.ps1 -Action apply
#              .\setup-sudo-chronyc.ps1 -Action remove
# 記録       : data/time-sync/setup-sudo-chronyc-<動作>-<時刻>.txt（パスワードは記録しない）。

param(
    [Parameter(Mandatory = $true)][ValidateSet("check", "apply", "remove")][string]$Action,
    [string[]]$Only = @(),
    [string]$User = "user"
)

$Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$vms = [ordered]@{ client = 2222; server = 2223; switch = 2224; router = 2225; router2 = 2226 }
$logDir = Join-Path $PSScriptRoot "..\..\data\time-sync"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$outFile = Join-Path $logDir ("setup-sudo-chronyc-{0}-{1}.txt" -f $Action, (Get-Date -Format "yyyyMMddTHHmmss"))
function Log($s) { Write-Host $s; Add-Content -Path $outFile -Value $s -Encoding UTF8 }

Log ("# setup-sudo-chronyc.ps1  action={0}  {1}" -f $Action, (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))
$n = 0
foreach ($name in $vms.Keys) {
    if ($Only.Count -gt 0 -and $Only -notcontains $name) { continue }
    $n++
    $port = $vms[$name]
    Log ""
    Log "=== $name (port $port) : $Action ==="
    # 二重引用符を使わない（Windows PowerShell 5.1 は外部コマンドの引数内の二重引用符を崩すため）。リモートは bash。
    $guard = 'test $(hostname -s) = __NAME__'.Replace('__NAME__', $name)
    switch ($Action) {
        "check" {
            $cmd = $guard + ' && P=$(command -v chronyc) && echo chronyc_path:$P && sudo -n -l $P burst 4/4 && sudo -n -l $P makestep'
            & ssh -o BatchMode=yes -p $port "${User}@127.0.0.1" $cmd
            Log ("  終了コード: {0}（0 = 2つとも、パスワードなしで実行可能）" -f $LASTEXITCODE)
        }
        "apply" {
            $cmd = $guard + ' && P=$(command -v chronyc) && printf ''%s ALL=(root) NOPASSWD: %s burst 4/4, %s makestep\n'' ' + $User + ' $P $P > /tmp/lab-chronyc.sudoers && sudo visudo -cf /tmp/lab-chronyc.sudoers && sudo install -o root -g root -m 440 /tmp/lab-chronyc.sudoers /etc/sudoers.d/lab-chronyc ; rm -f /tmp/lab-chronyc.sudoers ; sudo -n -l $P burst 4/4 && sudo -n -l $P makestep && echo apply-ok:$(hostname -s)'
            & ssh -t -p $port "${User}@127.0.0.1" $cmd
            Log ("  終了コード: {0}（0 で apply-ok:{1} が表示されていれば成功）" -f $LASTEXITCODE, $name)
        }
        "remove" {
            $cmd = $guard + ' && sudo rm -f /etc/sudoers.d/lab-chronyc && echo remove-ok:$(hostname -s)'
            & ssh -t -p $port "${User}@127.0.0.1" $cmd
            Log ("  終了コード: {0}（0 で remove-ok:{1} が表示されていれば成功）" -f $LASTEXITCODE, $name)
        }
    }
}
if ($n -eq 0) { Log ("警告: 対象のVMがありません（利用可能: " + ($vms.Keys -join ", ") + "）。") }
Log ""
Log "記録: $outFile"
