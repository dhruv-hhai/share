# share README demo — side-by-side: alice (mac) pushes, bob (hetzner) pulls.
# Reproduce: bash demo-setup.sh is invoked by the hidden block below.
Output share-demo.gif

Set Shell "bash"
Set FontSize 15
Set Width 1320
Set Height 600
Set Padding 12
Set TypingSpeed 40ms
Set Theme "Catppuccin Mocha"

Hide
Type "bash demo-setup.sh && tmux -L demo attach -t demo"
Enter
Sleep 7

Show
Sleep 1
Type "ls notes/"
Enter
Sleep 2.5

Type "share push --friend bob ./notes"
Enter
Sleep 6

# over to bob
Ctrl+B
Right
Sleep 1.5

Type "share pull --friend alice"
Enter
Sleep 12

Type "ls share/alice/notes/"
Enter
Sleep 3

# back to alice — push returned
Ctrl+B
Left
Sleep 3
