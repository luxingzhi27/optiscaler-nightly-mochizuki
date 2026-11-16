param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'ManagerStore.ps1')
. (Join-Path $PSScriptRoot 'ManagerEngine.ps1')
$script:root = Get-ManagerRoot
$script:work = Join-Path $script:root 'versions'
$script:latestTag = ''
$script:job = $null
$script:games = @{}
$script:summaries = @{}
$script:dllCounts = @{NR=0;RR=0}

function Make-Control([string]$Type,[string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H) {
    $c=New-Object ("System.Windows.Forms." + $Type)
    $c.Text=$Text; $c.SetBounds($X,$Y,$W,$H)
    return ,$c
}
function Put-Control($Parent,[string]$Type,[string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H) {
    $c=Make-Control $Type $Text $X $Y $W $H
    $Parent.Controls.Add($c)
    return ,$c
}
function Pick-File([string]$Title,[string]$Filter) {
    $picker=New-Object System.Windows.Forms.OpenFileDialog
    try {
        $picker.Title=$Title; $picker.Filter=$Filter; $picker.CheckFileExists=$true
        if ($picker.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $picker.FileName }
    } finally { $picker.Dispose() }
    return $null
}
function Show-Notice([string]$Text,[string]$Kind='Information') {
    [void][System.Windows.Forms.MessageBox]::Show($form,$Text,'OptiScaler 管理器',
        [System.Windows.Forms.MessageBoxButtons]::OK,([System.Windows.Forms.MessageBoxIcon]$Kind))
}
function Ask-Yes([string]$Text) {
    return [System.Windows.Forms.MessageBox]::Show($form,$Text,'OptiScaler 管理器',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2) -eq [System.Windows.Forms.DialogResult]::Yes
}
function Ux-Error($ErrorRecord) {
    $text=$ErrorRecord.Exception.Message
    $status.Text='操作未完成。请查看提示。'
    Show-Notice $text 'Warning'
}
function Current-Game {
    if ($list.SelectedItems.Count -ne 1) { return $null }
    return $script:games[[string]$list.SelectedItems[0].Tag]
}
function Refresh-Library {
    foreach ($entry in @(@('NR',$nrLabel),@('RR',$rrLabel))) {
        $kind=$entry[0]; $label=$entry[1]
        try {
            $script:dllCounts[$kind]=@(Get-ManagerDlls -Kind $kind).Count
            $dll=Get-ManagerDefaultDll -Kind $kind
            $label.Text=if ($dll) { "$kind DLL：已导入 $($dll.version)" } else { "$kind DLL：未导入（用到时再选）" }
        } catch { $label.Text="$kind DLL：无法校验，可重新导入。" }
    }
    Update-Controls
}
function Pick-ImportedDll([string]$Kind) {
    $records=@(Get-ManagerDlls -Kind $Kind)
    if ($records.Count -lt 2) { return }
    $dialog=Make-Control 'Form' "选择已导入的 $Kind DLL" 0 0 450 295
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.Font=$form.Font
    $box=Put-Control $dialog ListBox '' 14 15 400 163
    foreach ($r in $records) { [void]$box.Items.Add(($r.version+'  ·  '+$r.sha256.Substring(0,12))) }
    $box.SelectedIndex=0
    $ok=Put-Control $dialog Button '使用这个版本' 169 196 118 34
    $cancel=Put-Control $dialog Button '取消' 297 196 118 34
    $ok.DialogResult='OK';$cancel.DialogResult='Cancel';$dialog.AcceptButton=$ok;$dialog.CancelButton=$cancel
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $null=Set-ManagerDefaultDll -Kind $Kind -Id $records[$box.SelectedIndex].id
            Refresh-Library
            $status.Text="已选用库中已有的 $Kind DLL。"
        }
    } finally { $dialog.Dispose() }
}
function Import-FromUi([string]$Kind) {
    $name=if ($Kind -eq 'NR') { 'nvngx_dlssnr.dll' } else { 'nvngx_dlssd.dll' }
    $path=Pick-File "导入 $name（只保存在本机）" "$name|$name"
    if (-not $path) { return $null }
    $dll=Add-ManagerDll -Kind $Kind -Path $path -SetDefault
    Refresh-Library
    $status.Text="已导入 $Kind DLL $($dll.version)，后续可直接复用。"
    return $dll
}
function Update-Controls {
    $game=Current-Game
    $s=if ($game) { $script:summaries[$game.id] }
    $busy=$null -ne $script:job
    $running=$s -and $s.Running
    $existing=$s -and $s.State -eq 'Existing'
    $fresh=$s -and $s.State -eq 'Fresh'
    $gameName.Text=if ($game) { $game.name } else { '未选择游戏' }
    $gamePath.Text=if ($game) { $game.game_dir } else { '先添加游戏，旧版可直接接管。' }
    $install.Text=if ($fresh) { '安装组合包' } else { '更新此游戏' }
    $install.Enabled=(-not $busy) -and (-not $running) -and ($existing -or $fresh)
    $fgApply.Enabled=(-not $busy) -and (-not $running) -and $existing
    $backend.Enabled=$fgApply.Enabled
    $rr.Enabled=(-not $busy) -and (-not $running) -and $existing -and -not $s.OpenRR
    $rollback.Enabled=(-not $busy) -and (-not $running) -and $existing -and $s.CanRollback
    $open.Enabled=(-not $busy) -and $null -ne $game -and (Test-Path -LiteralPath $game.game_dir -PathType Container)
    $add.Enabled=-not $busy; $check.Enabled=-not $busy; $refresh.Enabled=-not $busy
    $nrImport.Enabled=-not $busy; $rrImport.Enabled=-not $busy
    $nrPick.Enabled=(-not $busy) -and $script:dllCounts.NR -gt 1
    $rrPick.Enabled=(-not $busy) -and $script:dllCounts.RR -gt 1
    $updateAll.Enabled=(-not $busy) -and (@($script:summaries.Values | Where-Object { $_.State -eq 'Existing' -and -not $_.Running }).Count -gt 0)
    $toolTip.SetToolTip($stateInfo,[string]$s.Reason)
    $stateInfo.Text=if ($running) { '先退出游戏，再点刷新列表。' } elseif ($existing -and $s.OpenRR) { 'OpenRR：已安装' } elseif ($existing) { 'OpenRR：未安装' } elseif ($s -and $s.State -eq 'Unsupported') { '请关闭游戏，再点刷新列表。' } else { '' }
}
function Refresh-Games([string]$Keep='') {
    if (-not $Keep -and $list.SelectedItems.Count) { $Keep=[string]$list.SelectedItems[0].Tag }
    $list.BeginUpdate()
    try {
        $list.Items.Clear(); $script:games=@{}; $script:summaries=@{}
        foreach ($g in @(Get-ManagerGames)) {
            if (-not $g.id) { continue }
            $script:games[$g.id]=$g
            try { $s=Get-ManagerGameStatus $g.game_dir } catch { $s=[pscustomobject]@{State='Unsupported';Mode='';Version='';CanRollback=$false;OpenRR=$false} }
            $script:summaries[$g.id]=$s
            $item=[Windows.Forms.ListViewItem]::new([string]$g.name); $item.Tag=[string]$g.id
            $item.ToolTipText=$g.game_dir
            $statusText=switch ($s.State) {
                'Fresh' {'未安装'}
                'Existing' { if ($s.Running) {'运行中'} elseif ($script:latestTag -and $s.Version -ceq $script:latestTag) {'版本一致'} elseif ($script:latestTag) {'可检查更新'} else {'已安装'} }
                default {if ($s.Running) {'运行中'} else {'需检查'}}
            }
            [void]$item.SubItems.Add([string]$statusText)
            $version=if ($s.Version -match '^bundle-(\d{8})-([a-f0-9]{6})') { $Matches[1]+' · '+$Matches[2] } elseif ($s.State -eq 'Existing') { '旧安装' } else { '—' }
            [void]$item.SubItems.Add($version)
            [void]$item.SubItems.Add($(if ($s.Mode -in @('ANR','XeMFG')) { [string]$s.Mode } elseif ($s.State -eq 'Existing') {'自定义'} else {'—'}))
            [void]$list.Items.Add($item)
            if ($g.id -eq $Keep) { $item.Selected=$true }
        }
        if (-not $list.SelectedItems.Count -and $list.Items.Count) { $list.Items[0].Selected=$true }
    } finally { $list.EndUpdate() }
    Update-Controls
}
function Start-ManagerOperation([string]$Action,$Request,[string]$Caption) {
    if ($script:job) { return }
    $ps=[PowerShell]::Create()
    $operation={
        param($Dir,$Work,$Action,$Request)
        $ErrorActionPreference='Stop'
        $ProgressPreference='SilentlyContinue'
        . (Join-Path $Dir 'ManagerEngine.ps1')
        $current=$null
        switch ($Action) {
            'Smoke' {
                foreach ($name in @('Get-ManagerGameStatus','Install-ManagerGame','Update-ManagerGame','Set-ManagerFg','Restore-ManagerBackup')) {
                    if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { throw "Missing backend operation $name" }
                }
                [pscustomobject]@{Message='manager-worker-ok'}
            }
            'Check' {
                $current=Get-ManagerLatest $Work
                [pscustomobject]@{Tag=$current.Lock.release_tag;Message=('已检查，最新版本：'+$current.Lock.release_tag)}
            }
            'Install' {
                $current=Get-ManagerLatest $Work
                $null=Install-ManagerGame $Request.exe $Request.dll $current
                [pscustomobject]@{Tag=$current.Lock.release_tag;Message='安装完成。'}
            }
            'Update' {
                $current=Get-ManagerLatest $Work
                $updated=Update-ManagerGame $Request.game $current
                $message=if ($updated.Changed) {'已更新。原有设置和模型未重置。'} else {'已经是最新版，没有改动。'}
                [pscustomobject]@{Tag=$current.Lock.release_tag;Message=$message}
            }
            'UpdateAll' {
                $current=Get-ManagerLatest $Work
                $ok=0; $warnings=@()
                foreach ($g in @($Request.games)) {
                    try { $null=Update-ManagerGame $g.game_dir $current; $ok++ }
                    catch { $warnings+=("$($g.name)："+$_.Exception.Message) }
                }
                [pscustomobject]@{Tag=$current.Lock.release_tag;Message=("已处理 $ok 款游戏，"+$warnings.Count+' 款未更新。');Warnings=$warnings}
            }
            'Switch' {
                $fg=Get-BundleFgStatus $Request.game
                if (($Request.mode -eq 'ANR' -and -not $fg.HasAnr) -or ($Request.mode -eq 'XeMFG' -and -not $fg.HasMfg)) {
                    $current=Get-ManagerLatest $Work
                }
                $null=Set-ManagerFg $Request.game $Request.mode $current
                [pscustomobject]@{Message=("已切换到 "+$Request.mode+'。重新启动游戏后生效。')}
            }
            'OpenRR' {
                $current=Get-ManagerLatest $Work
                $null=Enable-ManagerOpenRR $Request.game $Request.dll $current
                [pscustomobject]@{Message='已启用 OpenRR。进入支持的游戏后打开光线重建。'}
            }
            'Restore' {
                $null=Restore-ManagerBackup $Request.game $Request.backup
                [pscustomobject]@{Message='已回退该游戏。'}
            }
        }
    }
    [void]$ps.AddScript($operation.ToString()).AddArgument($PSScriptRoot).AddArgument($script:work).AddArgument($Action).AddArgument($Request)
    try { $handle=$ps.BeginInvoke() } catch { $ps.Dispose(); throw }
    $script:job=@{ps=$ps;handle=$handle;caption=$Caption}
    $status.Text=$Caption
    $bar.Style=[Windows.Forms.ProgressBarStyle]::Marquee
    Update-Controls
    $timer.Start()
}

$form=Make-Control 'Form' 'OptiScaler 管理器' 0 0 920 630
$form.StartPosition='CenterScreen'
$form.MinimumSize=[Drawing.Size]::new(920,630)
$form.Font=[Drawing.Font]::new('Microsoft YaHei UI',9)
$form.BackColor=[Drawing.Color]::FromArgb(243,247,252)
$allAnchor=[Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$rightAnchor=[Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Top
$bottomAnchor=[Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom

$title=Put-Control $form Label 'OptiScaler 管理器' 22 18 560 35
$title.Font=[Drawing.Font]::new('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold)
$sub=Put-Control $form Label '安装、更新、帧生成切换，都在这里。' 24 57 600 25
$add=Put-Control $form Button '＋ 添加游戏' 22 90 114 33
$check=Put-Control $form Button '检查更新' 146 90 100 33
$updateAll=Put-Control $form Button '更新已安装游戏' 257 90 140 33
$refresh=Put-Control $form Button '刷新列表' 408 90 92 33
$latestLabel=Put-Control $form Label '' 512 99 364 24; $latestLabel.Anchor=$allAnchor
$list=Put-Control $form ListView '' 22 135 586 275
$list.Anchor=$allAnchor -bor [Windows.Forms.AnchorStyles]::Bottom
$list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$false;$list.HideSelection=$false;$list.ShowItemToolTips=$true
foreach ($col in @(@('游戏',212),@('状态',100),@('安装版本',155),@('帧生成',102))) { [void]$list.Columns.Add([string]$col[0],[int]$col[1]) }

$details=Put-Control $form GroupBox '选中的游戏' 623 135 255 275; $details.Anchor=$rightAnchor -bor [Windows.Forms.AnchorStyles]::Bottom
$gameName=Put-Control $details Label '' 13 24 228 23; $gameName.AutoEllipsis=$true
$gamePath=Put-Control $details Label '' 13 48 228 20; $gamePath.AutoEllipsis=$true
$install=Put-Control $details Button '更新此游戏' 13 75 228 34
$backend=Put-Control $details ComboBox '' 13 120 110 24; $backend.DropDownStyle='DropDownList'
[void]$backend.Items.AddRange([object[]]@('ANR','XeMFG')); $backend.SelectedIndex=0
$fgApply=Put-Control $details Button '切换帧生成' 130 117 111 31
$rr=Put-Control $details Button '启用 OpenRR' 13 158 110 31
$rollback=Put-Control $details Button '回退…' 130 158 111 31
$open=Put-Control $details Button '打开游戏目录' 13 199 228 31
$stateInfo=Put-Control $details Label '' 13 239 228 22

$library=Put-Control $form GroupBox '本地 DLL 库（换版本不用重选）' 22 424 856 87; $library.Anchor=$bottomAnchor
$nrLabel=Put-Control $library Label '' 13 25 370 22
$rrLabel=Put-Control $library Label '' 432 25 370 22
$nrImport=Put-Control $library Button '导入 NR DLL…' 13 48 154 28
$rrImport=Put-Control $library Button '导入 RR DLL…' 432 48 154 28
$nrPick=Put-Control $library Button '选用已有版本…' 180 48 136 28
$rrPick=Put-Control $library Button '选用已有版本…' 599 48 136 28
$bar=Put-Control $form ProgressBar '' 22 527 856 5; $bar.Anchor=$bottomAnchor
$status=Put-Control $form Label '第一次添加旧游戏，只接管，不改文件。' 22 540 856 25; $status.Anchor=$bottomAnchor; $status.AutoEllipsis=$true
$secondary=Put-Control $form Label 'DLL 只保存在本机。切换后端前请退出游戏。XeMFG 路径适用于 DX12。' 22 567 856 22
$secondary.Anchor=$bottomAnchor; $secondary.ForeColor=[Drawing.Color]::FromArgb(67,87,111)

$toolTip=New-Object Windows.Forms.ToolTip
$timer=New-Object Windows.Forms.Timer; $timer.Interval=180
$timer.Add_Tick({
    if (-not $script:job -or -not $script:job.handle.IsCompleted) { return }
    $timer.Stop()
    $active=$script:job; $script:job=$null
    try {
        $out=@($active.ps.EndInvoke($active.handle))
        if ($active.ps.HadErrors) { throw ($active.ps.Streams.Error | Select-Object -First 1) }
        $last=$out | Where-Object { $_.PSObject.Properties['Message'] } | Select-Object -Last 1
        if (-not $last) { throw '操作没有返回可确认的结果。' }
        if ($last.Tag) {
            $script:latestTag=[string]$last.Tag
            $latestLabel.Text='最新：'+$script:latestTag
        }
        $status.Text=[string]$last.Message
        if (@($last.Warnings | Where-Object { $_ }).Count) { Show-Notice ($last.Message+"`r`n"+($last.Warnings -join "`r`n")) 'Warning' }
    } catch { Ux-Error $_ }
    finally {
        $active.ps.Dispose(); $bar.Style=[Windows.Forms.ProgressBarStyle]::Blocks
        Refresh-Games
    }
})
$list.Add_SelectedIndexChanged({
    $g=Current-Game
    if ($g -and $script:summaries[$g.id].Mode -in @('ANR','XeMFG')) { $backend.SelectedItem=$script:summaries[$g.id].Mode }
    Update-Controls
})
$add.Add_Click({
    try {
        $p=Pick-File '选择游戏实际运行的 EXE' '游戏 EXE|*.exe'
        if ($p) { $g=Register-ManagerGame -ExePath $p; Refresh-Games $g.id; $status.Text='游戏已加入列表，未改动游戏文件。' }
    } catch { Ux-Error $_ }
})
$nrImport.Add_Click({ try { $null=Import-FromUi NR } catch { Ux-Error $_ } })
$rrImport.Add_Click({ try { $null=Import-FromUi RR } catch { Ux-Error $_ } })
$nrPick.Add_Click({ try { Pick-ImportedDll NR } catch { Ux-Error $_ } })
$rrPick.Add_Click({ try { Pick-ImportedDll RR } catch { Ux-Error $_ } })
$refresh.Add_Click({ try { Refresh-Games; $status.Text='已刷新本地游戏状态。' } catch { Ux-Error $_ } })
$check.Add_Click({ try { Start-ManagerOperation Check @{} '正在检查新版…' } catch { Ux-Error $_ } })
$install.Add_Click({
    try {
        $g=Current-Game
        if ($script:summaries[$g.id].State -eq 'Fresh') {
            $dll=Get-ManagerDefaultDll -Kind NR
            if (-not $dll) { $dll=Import-FromUi NR }
            if (-not $dll) { return }
            Start-ManagerOperation Install @{exe=$g.exe_path;dll=$dll.path} '正在安装，首次需要下载和本地提取模型…'
        } else { Start-ManagerOperation Update @{game=$g.game_dir} '正在检查并更新该游戏…' }
    } catch { Ux-Error $_ }
})
$updateAll.Add_Click({
    try {
        $games=@($script:games.Values | Where-Object { $script:summaries[$_.id].State -eq 'Existing' -and -not $script:summaries[$_.id].Running })
        if ($games.Count -and (Ask-Yes "原地更新 $($games.Count) 款已安装游戏？请先退出这些游戏。")) {
            Start-ManagerOperation UpdateAll @{games=$games} '正在逐个更新游戏，已下载的组件会复用…'
        }
    } catch { Ux-Error $_ }
})
$fgApply.Add_Click({
    try {
        $g=Current-Game
        Start-ManagerOperation Switch @{game=$g.game_dir;mode=[string]$backend.SelectedItem} '正在切换帧生成…'
    } catch { Ux-Error $_ }
})
$rr.Add_Click({
    try {
        $g=Current-Game
        if (-not (Ask-Yes '为选中的游戏启用 OpenRR？本组合支持 RX 9000，游戏需要提供 DLSS 光线重建。')) { return }
        $dll=Get-ManagerDefaultDll -Kind RR
        if (-not $dll) { $dll=Import-FromUi RR }
        if ($dll) { Start-ManagerOperation OpenRR @{game=$g.game_dir;dll=$dll.path} '正在为此游戏启用 OpenRR…' }
    } catch { Ux-Error $_ }
})
$rollback.Add_Click({
    try {
        $g=Current-Game
        $backups=@(Get-ManagerBackups $g.game_dir)
        if (-not $backups.Count) { Show-Notice '这款游戏没有可用备份。';return }
        $b=$backups[0]
        $label=switch ($b.Profile) {
            'fg-switch' {'帧生成切换'}
            'game-update' {'组件更新'}
            'openrr' {'启用 OpenRR'}
            default {'配置变更'}
        }
        if (Ask-Yes ("回退这款游戏最近一次操作？`r`n"+$label+' · '+$b.Time.ToString('yyyy-MM-dd HH:mm'))) {
            Start-ManagerOperation Restore @{game=$g.game_dir;backup=$b.Path} '正在验证备份并回退…'
        }
    } catch { Ux-Error $_ }
})
$open.Add_Click({ try { $g=Current-Game; Invoke-Item -LiteralPath $g.game_dir } catch { Ux-Error $_ } })
$form.Add_FormClosing({ param($s,$e) if ($script:job) { $e.Cancel=$true; $status.Text='操作正在进行，请等当前写入完成再关闭。' } })
try {
    if ($SelfTest) {
        if ($form.Controls.Count -lt 10 -or $details.Controls.Count -lt 8 -or $backend.Items.Count -ne 2) { throw 'Manager UI construction failed.' }
        Refresh-Games
        Refresh-Library
        Start-ManagerOperation Smoke @{} 'Testing worker...'
        $active=$script:job
        try {
            if (-not $active.handle.AsyncWaitHandle.WaitOne(15000)) { throw 'Manager background worker did not initialize.' }
            $result=@($active.ps.EndInvoke($active.handle))
            if ($active.ps.HadErrors -or $result[-1].Message -cne 'manager-worker-ok') { throw ('Manager worker failed: '+($active.ps.Streams.Error | Out-String)) }
        } finally { $timer.Stop(); $active.ps.Dispose(); $script:job=$null }
        Write-Host 'Manager window and background operations constructed.'; return
    }
    Refresh-Games
    Refresh-Library
    [void]$form.ShowDialog()
} finally { $timer.Dispose(); $toolTip.Dispose(); $form.Dispose() }
