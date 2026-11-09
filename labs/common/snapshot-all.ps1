# 複数の VM を停止して、同じ名前のスナップショットを取る
#
# 対象ノード : Windows ホスト（PowerShell）から、VirtualBox の VM（既定: client / server / router / router2）
# 実行権限   : 一般ユーザー
# 状態変更   : あり。(1) 起動中の VM を ACPI の電源ボタンで停止する（ゲストが正常にシャットダウンする）。
#              (2) 電源OFFの VM にスナップショットを追加する。
#              VM のデータは変わらない。スナップショットの削除は別操作（このスクリプトは削除しない）。
# 前提       : 実験の teardown と、結果の回収（transfer.ps1 -Mode pull）が済んでいること。
#              スナップショットを復元すると、それ以降の VM 内のファイル（未回収の記録）は失われる。
# 復旧       : 不要になったスナップショットは VirtualBox マネージャーまたは `VBoxManage snapshot <VM> delete <名前>`。
# 使い方     :
#   .\snapshot-all.ps1 -Name exp6-done -Description "実験6完了。teardown済み、電源OFF"
#   .\snapshot-all.ps1 -Name exp6-done -DryRun          # 実行内容を表示するだけ（VM は変更しない）
#   .\snapshot-all.ps1 -Name exp6-done -Vms "Alma9mini-cli","Alma9mini-server"   # 対象を指定
#   -Yes で確認の入力を省略。-WaitSec で停止待ちの最大秒数（既定 120）。
#   .\snapshot-all.ps1                                   # 対話モード: VM の選択 → 名前 → 説明（名前と説明は選んだ全 VM で共通）→ 成功後に起動するか
#   .\snapshot-all.ps1 -Interactive -Vms "Alma9mini-cli"  # -Vms は対話モードでの既定の選択（* の付く VM）になる
#   -Start で、スナップショットが取れた VM を、指定した順に起動する（非対話でも使える）。起動の間隔は -StartIntervalSec（既定 10）。
#   -StartType gui|headless（既定 gui）。起動に失敗した VM は、間隔を置いて1回だけ再試行する。
# 安全装置   : 同名のスナップショットが既にある VM は、取らずにスキップする。電源OFFにならなかった VM もスキップする。
#              スナップショットを取った後の初回起動が失敗することがある（docs/NEXT_STEPS.md §10）。その場合はもう一度起動する。

param(
    [string]$Name = "",
    [string]$Description = "",
    [string[]]$Vms = @("Alma9mini-cli", "Alma9mini-server", "Alma9mini-router", "Alma9mini-router2"),
    [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
    [int]$WaitSec = 120,
    [switch]$Interactive,
    [switch]$Start,
    [int]$StartIntervalSec = 10,
    [ValidateSet("gui", "headless")][string]$StartType = "gui",
    [switch]$DryRun,
    [switch]$Yes
)

# powershell -File で起動すると、-Vms a,b は1つの文字列になるため、カンマで分割する
$Vms = @($Vms | ForEach-Object { $_ -split "," } | Where-Object { $_ })

if (-not (Test-Path $VBoxManage)) { Write-Host "VBoxManage.exe が見つかりません: $VBoxManage"; exit 1 }

function Get-State($vm) {
    $line = (& $VBoxManage showvminfo $vm --machinereadable 2>&1 | Select-String '^VMState=')
    if (-not $line) { return "unknown" }
    return ($line.ToString() -replace '^VMState="', '' -replace '"$', '')
}
function Has-Snapshot($vm, $snap) {
    $out = & $VBoxManage snapshot $vm list --machinereadable 2>&1 | Out-String
    return ($out -match ('SnapshotName(-\d+)*="' + [regex]::Escape($snap) + '"'))
}

function Read-Default($prompt, $default) {
    $v = Read-Host ($prompt + $(if ($default) { "（Enter = $default）" } else { "" }))
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v.Trim()
}

if ($Interactive -or -not $Name) {
    # 対話モード。選ぶ VM は VirtualBox に登録済みのもの。起動の順番は選んだ順
    $all = @(& $VBoxManage list vms | ForEach-Object { if ($_ -match '^"(.+)" \{') { $Matches[1] } })
    if (-not $all) { Write-Host "登録された VM がありません"; exit 1 }
    Write-Host "停止してスナップショットを取る VM を選んでください（* = 既定の選択）:"
    for ($i = 0; $i -lt $all.Count; $i++) {
        $mark = if ($Vms -contains $all[$i]) { "*" } else { " " }
        Write-Host ("  {0}) {1} {2,-22} 状態={3}" -f ($i + 1), $mark, $all[$i], (Get-State $all[$i]))
    }
    $sel = Read-Host "番号をカンマ区切りで（例: 1,3。選んだ順に起動します）。Enter = 既定、all = すべて"
    if ($sel -eq "all") { $Vms = $all }
    elseif (-not [string]::IsNullOrWhiteSpace($sel)) {
        $picked = @()
        foreach ($t in ($sel -split "[,\s]+" | Where-Object { $_ })) {
            $n = 0
            if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 1 -or $n -gt $all.Count) { Write-Host "番号が正しくありません: $t"; exit 1 }
            if ($picked -notcontains $all[$n - 1]) { $picked += $all[$n - 1] }
        }
        $Vms = $picked
    }
    $missing = @($Vms | Where-Object { $all -notcontains $_ })
    if ($missing) { Write-Host ("登録されていない VM があります: " + ($missing -join ", ")); exit 1 }
    if (-not $Vms) { Write-Host "VM が選ばれていません"; exit 1 }
    $Name = Read-Default "スナップショットの名前" ($(if ($Name) { $Name } else { "snap-" + (Get-Date -Format "yyyyMMdd-HHmm") }))
    $Description = Read-Default "説明（全 VM 共通。省略可）" $Description
    if (-not $Start) {
        $a = Read-Host "スナップショットが取れた VM を、選んだ順に $StartIntervalSec 秒間隔で起動しますか？ (Y/n)"
        $Start = ($a -ne "n")
    }
}

Write-Host "スナップショット名: $Name"
if ($Description) { Write-Host "説明: $Description" }
Write-Host ("対象: " + ($Vms -join ", "))
if ($Start) { Write-Host ("成功後の起動: する（上の順、$StartIntervalSec 秒間隔、種類=$StartType）") } else { Write-Host "成功後の起動: しない" }
if ($DryRun) { Write-Host "（DryRun: VM は変更しません）" }
Write-Host ""
Write-Host "現在の状態:"
foreach ($vm in $Vms) {
    $st = Get-State $vm
    $has = if ($st -eq "unknown") { "-" } elseif (Has-Snapshot $vm $Name) { "同名あり" } else { "なし" }
    Write-Host ("  {0,-20} 状態={1,-10} 同名のスナップショット={2}" -f $vm, $st, $has)
}
Write-Host ""

if (-not $DryRun -and -not $Yes) {
    $ans = Read-Host "起動中の VM を停止して、スナップショットを取ります。続けますか？ (y/N)"
    if ($ans -ne "y") { Write-Host "中止しました。"; exit 0 }
}

# 1. 停止要求
foreach ($vm in $Vms) {
    $st = Get-State $vm
    if ($st -eq "running") {
        if ($DryRun) { Write-Host "[$vm] （DryRun）ACPI の電源ボタンで停止を要求します（実行しません）" }
        else { Write-Host "[$vm] ACPI の電源ボタンで停止を要求します"; & $VBoxManage controlvm $vm acpipowerbutton }
    }
}

# 2. 停止待ちとスナップショット
foreach ($vm in $Vms) {
    $limit = (Get-Date).AddSeconds($WaitSec)
    $st = Get-State $vm
    if (-not $DryRun) {
        while ($st -ne "poweroff" -and $st -ne "unknown" -and (Get-Date) -lt $limit) {
            Start-Sleep -Seconds 3
            $st = Get-State $vm
        }
    }
    if ($DryRun) { Write-Host "[$vm] （DryRun）状態=$st。電源OFFになれば、スナップショット '$Name' を取ります"; continue }
    if ($st -ne "poweroff") { Write-Host "[$vm] スキップ: 電源OFFになりませんでした（状態=$st）。VM 内で sudo poweroff を実行して、再実行してください"; continue }
    if (Has-Snapshot $vm $Name) { Write-Host "[$vm] スキップ: 同名のスナップショットが既にあります"; continue }
    Write-Host "[$vm] スナップショットを取ります"
    # 注意: VBoxManage は進捗(0%...100%)を標準エラー出力に書く。2>&1 でまとめると、Windows PowerShell 5.1 が
    #       NativeCommandError として表示してしまう（2026-10-24 に観測。スナップショット自体は成功していた）。まとめずにそのまま出す。
    # --description は「--description=値」の1語で渡す。分けて渡すと、-Description を省略した（空文字列の）ときに引数が落ち、
    #       「--description: Command line option needs argument」で失敗した（2026-10-27 に観測。原因は候補: Windows PowerShell 5.1 は空文字列のネイティブ引数を渡さない）。空のときは付けない。
    $snapArgs = @("snapshot", $vm, "take", $Name)
    if ($Description) { $snapArgs += "--description=$Description" }
    & $VBoxManage @snapArgs
    if ($LASTEXITCODE -ne 0) { Write-Host "[$vm] 失敗: VBoxManage の終了コード $LASTEXITCODE" }
}

Write-Host ""
Write-Host "完了。最終状態:"
foreach ($vm in $Vms) {
    Write-Host ("  {0,-20} 状態={1,-10} スナップショット '{2}'={3}" -f $vm, (Get-State $vm), $Name, $(if (Has-Snapshot $vm $Name) { "あり" } else { "なし" }))
}

# 3. 起動（-Start / 対話モードで選んだとき）。スナップショットがあり、電源OFFの VM だけを、指定した順に起動する。
#    スナップショット後の初回起動は失敗することがある（docs/NEXT_STEPS.md §10）ため、間隔を置いて1回だけ再試行する。
if ($Start) {
    Write-Host ""
    $targets = @($Vms | Where-Object { (Get-State $_) -eq "poweroff" -and (Has-Snapshot $_ $Name) })
    $skipped = @($Vms | Where-Object { $targets -notcontains $_ })
    if ($skipped) { Write-Host ("起動しない VM（スナップショットなし、または電源OFFでない）: " + ($skipped -join ", ")) }
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $vm = $targets[$i]
        if ($DryRun) { Write-Host "[$vm] （DryRun）起動します（種類=$StartType）"; }
        else {
            Write-Host "[$vm] 起動します（種類=$StartType）"
            & $VBoxManage startvm $vm --type $StartType
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[$vm] 起動に失敗（終了コード $LASTEXITCODE）。$StartIntervalSec 秒後に1回だけ再試行します"
                Start-Sleep -Seconds $StartIntervalSec
                & $VBoxManage startvm $vm --type $StartType
                if ($LASTEXITCODE -ne 0) { Write-Host "[$vm] 再試行も失敗（終了コード $LASTEXITCODE）。VirtualBox マネージャーで確認してください" }
            }
        }
        if (-not $DryRun -and $i -lt $targets.Count - 1) { Write-Host "  次の VM まで $StartIntervalSec 秒待ちます"; Start-Sleep -Seconds $StartIntervalSec }
    }
    if (-not $DryRun) { Write-Host ""; Write-Host "起動後の状態:"; foreach ($vm in $Vms) { Write-Host ("  {0,-20} 状態={1}" -f $vm, (Get-State $vm)) } }
}
