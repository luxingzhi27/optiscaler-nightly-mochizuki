function Select-UpdateGame([string]$Path) {
    if (-not $Path) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $picker = New-Object System.Windows.Forms.OpenFileDialog
            try {
                $picker.Title = 'Select an already modded game executable'
                $picker.Filter = 'Game executable (*.exe)|*.exe'
                $picker.CheckFileExists = $true
                if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
                $Path = $picker.FileName
            } finally { $picker.Dispose() }
        } catch { $Path = Read-Host 'Enter the game EXE or its folder (Enter cancels)' }
    }
    if (-not $Path) { return $null }
    $Path = $Path.Trim().Trim('"')
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { return $item.FullName }
    if ($item.Extension -ine '.exe') { throw 'Select an executable or its game folder.' }
    return $item.DirectoryName
}
