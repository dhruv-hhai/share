# share README demo — full flow: pair (invite/accept over PAKE), push, pull.
# demo-setup.sh stages the panes; demo-orchestrator.sh types into both.
# vhs is only the camera.
Output share-demo.gif

Set Shell "bash"
Set FontSize 15
Set Width 1320
Set Height 600
Set Padding 12
Set Theme "Catppuccin Mocha"

Hide
Type "bash demo-setup.sh && tmux -L demo attach -t demo"
Enter
Sleep 4

Show
Sleep 56
