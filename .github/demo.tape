# share README demo — real transfer: mac pushes, hetzner box pulls.
Output share-demo.gif

Set Shell "zsh"
Set FontSize 17
Set Width 1080
Set Height 640
Set Padding 16
Set TypingSpeed 35ms
Set Theme "Catppuccin Mocha"

Hide
Type `export $(grep -h SHARE_SECRET_ANALAYA ~/.zshrc | sed 's/export //;s/"//g') && cd $(mktemp -d) && mkdir notes && echo 'hello from the mac' > notes/hi.md && clear`
Enter
Sleep 1

Show
Type "share friends"
Enter
Sleep 2

Type "share push --friend analaya ./notes &"
Enter
Sleep 5

Type "ssh analaya share pull --friend mac"
Enter
Sleep 14

Type "ssh analaya cat 'share/mac/notes/hi.md'"
Enter
Sleep 4
