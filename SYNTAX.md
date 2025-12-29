# Dice Notation Syntax

A guide to the dice notation supported by `toss`.

## Overview

Dice notation is a standard format for describing dice rolls in tabletop RPGs. The basic form is `NdS` where you roll N dice with S sides each. Modifiers can be chained to create complex rolling mechanics.

## Basic Syntax

```
<count>d<sides>
```

| Component | Description | Default |
|-----------|-------------|---------|
| `count` | Number of dice to roll | 1 |
| `d` | Separator (literal) | required |
| `sides` | Number of sides per die | required |

**Examples:**
- `2d6` - Roll two 6-sided dice
- `d20` - Roll one 20-sided die (count defaults to 1)
- `4d8` - Roll four 8-sided dice

### Special Dice

| Notation | Description |
|----------|-------------|
| `d%` or `d100` | Percentile dice (1-100) |
| `dF` | Fudge/Fate dice (-1, 0, +1) |

## Modifiers

Modifiers are applied in a specific order regardless of how they appear in the notation.

### Keep/Drop

Filter which dice contribute to the total.

| Modifier | Description | Example |
|----------|-------------|---------|
| `k<n>` | Keep highest n dice | `4d6k3` |
| `kh<n>` | Keep highest n dice (explicit) | `4d6kh3` |
| `kl<n>` | Keep lowest n dice | `4d6kl1` |
| `d<n>` | Drop lowest n dice | `4d6d1` |
| `dl<n>` | Drop lowest n dice (explicit) | `4d6dl1` |
| `dh<n>` | Drop highest n dice | `4d6dh1` |

**Defaults:**
- `k` without `h`/`l` = keep highest
- `d` without `h`/`l` = drop lowest
- Without a number = 1

### Exploding Dice

Roll additional dice when certain values appear.

| Modifier | Description | Example |
|----------|-------------|---------|
| `!` | Explode on maximum value | `1d6!` |
| `!><n>` | Explode on values greater than n | `1d6!>4` |
| `!<<n>` | Explode on values less than n | `1d6!<3` |
| `!=<n>` | Explode on specific value | `1d6!=5` |
| `!!` | Compound explode (add to same die) | `1d6!!` |
| `!p` | Penetrating explode (subtract 1 from extras) | `1d6!p` |

**Default:** Without a threshold, dice explode on their maximum value.

**Safety limits:**
- Maximum 100 extra dice from explosions (prevents infinite loops)
- d1 and dF (Fudge dice) cannot explode (would always trigger)

### Reroll

Re-roll dice that meet certain conditions.

| Modifier | Description | Example |
|----------|-------------|---------|
| `r<n>` | Reroll on value n (continuous) | `2d6r1` |
| `r<<n>` | Reroll values less than n | `2d6r<3` |
| `r><n>` | Reroll values greater than n | `2d6r>5` |
| `r<=<n>` | Reroll values less than or equal to n | `2d6r<=2` |
| `ro<n>` | Reroll once on value n | `2d6ro1` |

**Default:** `r` without a value rerolls 1s.

### Order of Application

Modifiers are applied in this order:

1. **Exploding/Reroll** - Generate or replace dice
2. **Keep/Drop** - Filter which dice count
3. Arithmetic - Add/subtract from total

## Arithmetic

Combine dice rolls and constants with standard operators.

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Addition | `2d6+5` |
| `-` | Subtraction | `1d20-2` |
| `*` | Multiplication | `2d6*2` |
| `/` | Division | `1d10/2` |

**Chaining:** Multiple terms can be combined: `2d6+1d4+3`

## Examples

### Dungeons & Dragons

```bash
# Ability score generation (4d6, drop lowest)
toss 4d6d1

# Attack with advantage (roll 2d20, keep highest)
toss 2d20kh1

# Attack with disadvantage (roll 2d20, keep lowest)
toss 2d20kl1

# Greatsword damage
toss 2d6+5

# Great Weapon Fighting (reroll 1s and 2s once)
toss 2d6ro<=2+5

# Fireball damage
toss 8d6
```

### Savage Worlds

```bash
# Trait roll with wild die (both explode)
toss 1d8! 1d6!

# Damage roll
toss 2d6!+2
```

### World of Darkness

```bash
# Dice pool (count successes manually for now)
toss 5d10
```

### Shadowrun

```bash
# Dice pool with exploding 6s
toss 8d6!
```

### General

```bash
# Percentile roll with modifier
toss d%+10

# Fudge/Fate dice
toss 4dF

# Complex expression
toss 2d6+1d4+5
```

## Grammar

A formal-ish grammar for the dice notation parser:

```
expression  := term (('+' | '-') term)*
term        := factor (('*' | '/') factor)*
factor      := dice | number | '(' expression ')'

dice        := [count] 'd' sides [modifiers]
count       := number
sides       := number | '%' | 'F'

modifiers   := modifier*
modifier    := keep | drop | explode | reroll

keep        := 'k' ['h' | 'l'] [number]
            |  'kh' [number]
            |  'kl' [number]

drop        := 'd' ['h' | 'l'] [number]
            |  'dh' [number]
            |  'dl' [number]

explode     := '!' [compare_point]
            |  '!!' [compare_point]
            |  '!p' [compare_point]

reroll      := 'r' [compare_point]
            |  'ro' [compare_point]

compare_point := compare_op number
compare_op    := '=' | '>' | '<' | '>=' | '<=' | '!='

number      := digit+
digit       := '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9'
```

**Notes:**
- Square brackets `[]` indicate optional elements
- `*` indicates zero or more repetitions
- `+` indicates one or more repetitions
- `|` indicates alternatives
