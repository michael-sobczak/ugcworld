$scripts = "C:\Users\micha\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Scripts"
$old = [Environment]::GetEnvironmentVariable("Path", "User")
if ($old -notlike "*$scripts*") {
  [Environment]::SetEnvironmentVariable("Path", "$old;$scripts", "User")
  "Added to PATH (User): $scripts"
} else {
  "Already on PATH: $scripts"
}
