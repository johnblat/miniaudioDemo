if not exist build mkdir build
set name=miniaudio-example

set ODIN_PATH=
for /f %%i in ('odin root') do set "ODIN_PATH=%%i"

set OUT_DIR=build

if not exist "SDL3.dll" (
	if exist "%ODIN_PATH%\vendor\sdl3\SDL3.dll" (
		echo SDL3.dll not found in current directory. Copying from %ODIN_PATH%\vendor\sdl3\SDL3.dll
		copy "%ODIN_PATH%\vendor\sdl3\SDL3.dll" %OUT_DIR%
		IF %ERRORLEVEL% NEQ 0 exit /b 1
	) else (
		echo "Please copy SDL3.dll from <your_odin_compiler>/vendor/sdl3/SDL3.dll to the same directory as game.exe"
		exit /b 1
	)
)

if not exist "SDL3.lib" (
	if exist "%ODIN_PATH%\vendor\sdl3\SDL3.lib" (
		echo SDL3.lib not found in current directory. Copying from %ODIN_PATH%\vendor\sdl3\SDL3.lib
		copy "%ODIN_PATH%\vendor\sdl3\SDL3.lib" %OUT_DIR%
		IF %ERRORLEVEL% NEQ 0 exit /b 1
	) else (
		echo "Please copy SDL3.lib from <your_odin_compiler>/vendor/sdl3/SDL3.lib to the same directory as game.exe"
		exit /b 1
	)
)

odin build src/main_default -debug -out:%OUT_DIR%\%name%.exe
