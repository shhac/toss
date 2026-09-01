# toss demo recording
# Run: vhs assets/demo.tape
#
# toss is self-contained: it reads no files, needs no network, and touches
# nothing outside its own process. There is no setup script for this tape.
Output assets/demo.gif
Output assets/demo.webm

Set Theme "Catppuccin Mocha"
Set FontFamily "Fira Code"
Set FontSize 15
Set Width 680
Set Height 400
Set Padding 16
Set Framerate 5
Set TypingSpeed 50ms
Set CursorBlink false

Hide
Type "clear"
Enter
Sleep 300ms
Show

# D&D ability scores: roll 4d6, keep the highest 3
Type "toss 4d6k3"
Sleep 200ms
Enter
Sleep 2s

# Advantage: two d20s, keep the higher
Type "toss 2d20kh1"
Sleep 200ms
Enter
Sleep 2s

# Exploding dice — a max roll rolls again
Type "toss '3d6!'"
Sleep 200ms
Enter
Sleep 2s

# Great Weapon Fighting: reroll 1s and 2s, once
Type "toss '2d6ro<=2'"
Sleep 200ms
Enter
Sleep 2s

# Everything at once, plus a modifier
Type "toss '4d6!r1k3+5'"
Sleep 200ms
Enter
Sleep 2.5s

# Same seed, same roll — reproducible when you need it
Type "toss --seed 42 2d6"
Sleep 200ms
Enter
Sleep 1.5s
Type "toss --seed 42 2d6"
Sleep 200ms
Enter
Sleep 3s
