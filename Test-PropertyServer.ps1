# Test PropertyServer connectivity
Write-Host "Testing PropertyServer on 127.0.0.1:18082..."

$host = "127.0.0.1"
$port = 18082

try {
    $socket = New-Object System.Net.Sockets.TcpClient
    $socket.Connect($host, $port)
    
    if ($socket.Connected) {
        Write-Host "✓ CONNECTED - PropertyServer is running and responding!" -ForegroundColor Green
        
        # Try to read initial response
        $stream = $socket.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream)
        
        Write-Host ""
        Write-Host "Sending test commands..."
        
        # Try different commands
        @("info", "status", "getproperties", "disconnect") | ForEach-Object {
            Write-Host ""
            Write-Host "→ Command: $_"
            $writer.WriteLine($_)
            $writer.Flush()
            
            Start-Sleep -Milliseconds 50
            
            # Try to read response with timeout
            $stream.ReadTimeout = 500
            try {
                if ($stream.DataAvailable) {
                    $response = $reader.ReadLine()
                    if ($response) {
                        Write-Host "← Response: $response" -ForegroundColor Cyan
                    }
                    else {
                        Write-Host "← (empty response)" -ForegroundColor Gray
                    }
                }
                else {
                    Write-Host "← (no data available)" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host "← (timeout/error)" -ForegroundColor Gray
            }
        }
        
        $reader.Close()
        $writer.Close()
        $stream.Close()
    }
    else {
        Write-Host "✗ Connection failed - socket not connected" -ForegroundColor Red
    }
}
catch [System.Net.Sockets.SocketException] {
    Write-Host "✗ CONNECTION FAILED - PropertyServer not responding on $host`:$port" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
}
catch {
    Write-Host "✗ ERROR: $_" -ForegroundColor Red
}
finally {
    if ($socket) { $socket.Close() }
}

Write-Host ""
Write-Host "Test complete."
