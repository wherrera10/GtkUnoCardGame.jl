using Random, Colors, Gtk, Cairo

#=========== Channel section ===================#

""" channel, communicates player's mouse choice of card or color to game logic """
channel = Channel{Any}(100)

""" flush the channel from mouse choice to game logic """
flushchannel() = while !isempty(channel) take!(channel); end

#============ Game play section ==================#

""" The Uno card type. The first field is color, second field is number or command. """
const UnoCard = Pair{String, String}
color(c::UnoCard) = first(c)
type(c::UnoCard) = last(c)

""" Each Uno player has a name, a score, may be a bot, and has a hand of UnoCards. """
mutable struct UnoCardGamePlayer
    name::String
    score::Int
    isabot::Bool
    hand::Vector{UnoCard}
end

"""
    mutable struct UnoCardGameState
Encapsulates a board state of the gane, including players, cards, color being played,
order of play, current player, and whether the card showing has had its command used
"""
mutable struct UnoCardGameState
    drawpile::Vector{UnoCard}
    discardpile::Vector{UnoCard}
    players::Vector{UnoCardGamePlayer}
    pnow::Int
    colornow::String
    lastcolor::String
    clockwise::Bool
    commandsvalid::Bool
end

""" classifications of colors and types for card faces """
const colors = ["Red", "Yellow", "Green", "Blue"]  # suit colors
const types = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Skip", "Draw Two", "Reverse"]
const numtypes = types[begin:end-3]
const wildtypes = ["Wild", "Draw Four"]
const cmdtypes = vcat(types[end-2:end], wildtypes)
const alltypes = vcat(types, wildtypes)
const unopreferred = ["Skip", "Draw Two", "Reverse", "Draw Four"]
const ttypes = sort!(vcat(types, types))
const typeordering = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Wild", "Skip",
    "Reverse", "Draw Two", "Draw Four"]
popfirst!(ttypes) # only 1 "0" card per color

""" The Uno card game deck, unshuffled. """
const originaldeck = [vec([UnoCard(c, v) for v in ttypes, c in colors]);
      fill(UnoCard("Wild", "Wild"), 4); fill(UnoCard("Wild", "Draw Four"), 4)]

""" challenge flags: taken by player, display button """
const challenge = [false, false]


""" Set the next player to play to game.pnow (clockwise or counterclockwise) """
function nextplayer!(game, idx)
   game.pnow = mod1(game.clockwise ? idx + 1 : idx - 1, length(game.players))
end
nextplayer!(game) = nextplayer!(game, game.pnow)

"""
    nextsaiduno(game)
Returns true if the next player to play has said Uno, which means they have only one card left.
If so, it is best for the current player if they play to make them draw or lose a turn.
"""
function nextsaiduno(game)
    idx = game.pnow
    nextp = mod1(game.pnow + (game.clockwise ? 1 : -1), length(game.players))
    return length(game.players[nextp].hand) == 1
end

"""
    UnoCardGameState(playernames = ["Player", "Bot1", "Bot2", "Bot3"])
Construct and initialize Uno game. Includes dealing hands and picking who is to start.
"""
function UnoCardGameState(playernames = ["Player", "Bot1", "Bot2", "Bot3"])
    deck = shuffle(originaldeck)
    discardpile, drawpile = UnoCard[], UnoCard[]
    while true  # cannot start with a Draw Four on discard pile top
        discardpile, drawpile = [deck[29]], deck[30:end]
        last(last(discardpile)) != "Draw Four" && break
        deck[29:end] .= shuffle(deck[29:end])
    end
    hands = [deck[i:i+6] for i in 1:7:27]
    game = UnoCardGameState(drawpile, discardpile, [UnoCardGamePlayer(playernames[i],
        startswith(playernames[i], "Bot") ? true : false, hands[i])
        for i in 1:length(playernames)], 1, "Wild", "Wild", true, true)
    dealer = rand(1:length(playernames))
    logline("Player $(playernames[dealer]) is dealer.")
    # handle an initial Reverse card
    if type(last(discardpile)) == "Reverse"
            game.clockwise = false
            logline("First card Reverse, so starting counterclockwise with dealer.")
            game.commandsvalid = false
            game.pnow = dealer
    else
        nextplayer!(game, dealer)
    end
    logline("Player $(playernames[game.pnow]) starts play.")
    if color(last(discardpile)) == "Wild"
        choosecolor!(game)
        game.commandsvalid = false
    else
        game.colornow = color(last(discardpile))
    end
    return game
end

function nextgame(game::UnoCardGameState)
    newgame = UnoCardGameState()
    for i in eachindex(newgame.players)
        newgame.players[i].score = game.players[i]score
    end
    return newgame
end

cardvalue(c::UnoCard) = something(findfirst(x -> x == type(c), typeordering), 0)
countcolor(cards, clr) = count(c -> color(c) == clr, cards)
colorcounts(cards) = sort!([(countcolor(cards, clr), clr) for clr in colors])

""" Preferred color is the one that is most counted in the hand. """
preferredcolor(hand) = last(last(colorcounts(hand)))

"""
    playableindices(game)
Return a vector of indices of cards in hand that are legal to discard
"""
function playableindices(game)
    hand = game.players[game.pnow].hand
    mcolor, mtype = game.colornow, type(game.discardpile[end])
    return [i for (i, c) in enumerate(hand) if
        color(c) == mcolor || type(c) == mtype || color(c) == "Wild"]
end

""" Current player to draw n cards from the draw pile. """
function drawcardsfromdeck!(game, n=1)
    if n == 4  # draw four
        # bot will challenge half the time, player must challenge in 5 seconds.
        if game.players[game.pnow].isabot && rand() < 0.5  ||
            (!game.players[game.pnow].isabot && challenge[begin] == true)
            challenge[begin] = false
            logline("$(game.players[game.pnow].name) challenged Draw Four!")
            challenger, savecolor = game.pnow, game.colornow
            nextplayer!(game); nextplayer!(game); nextplayer!(game); # prior player
            game.colornow = game.lastcolor
            indices = playableindices(game)
            hand = game.players[game.pnow].hand
            if any(i -> color(hand[i]) != "Wild", playableindices(game))
                logline("Challenge sustained! Challenged player draws 4.")
                drawcardsfromdeck!(game, 4)
                game.pnow, game.colornow = challenger, savecolor
                return
            else
                logline("Challenge fails. Challenging player now draws 6.")
                n = 6
            end
            game.pnow, game.colornow = challenger, savecolor
        end
    end
    logline("Player $(game.players[game.pnow].name) draws $n card$(n == 1 ? "" : "s").")
    for _ in 1:n
        push!(game.players[game.pnow].hand, pop!(game.drawpile))
        if isempty(game.drawpile)
            game.drawpile = shuffle(game.discardpile[begin:end-1])
            game.discardpile = [game.discardpile[end]]
        end
    end
end

"""
    discard!(game, idx = -1)
Current player to discard card at index idx in hand (last card in hand as default).
Handle wild card discard by having current player choose the new game.colornow.
"""
function discard!(game, idx = -1)
    hand = game.players[game.pnow].hand
    if idx != -1
        hand[idx], hand[end] = hand[end], hand[idx]
    end
    push!(game.discardpile, pop!(hand))
    lastdiscard = last(game.discardpile)
    logline("Player $(game.players[game.pnow].name) discarded $lastdiscard")
    game.lastcolor = game.colornow
    if color(lastdiscard) == "Wild"  # wild card discard, so choose a color to be colornow
        choosecolor!(game)
        logline("New color chosen: $(game.colornow)")
    else
        game.colornow = color(lastdiscard)
    end
    game.commandsvalid = true
end

"""
    turn!(game)
Execute a single turn of the game.  Command cards are followed only the first turn after played.
"""
function turn!(game)
    name, hand = game.players[game.pnow].name, game.players[game.pnow].hand
    lastdiscard, indices = game.discardpile[end], playableindices(game)
    mcolor, mtype = game.colornow, type(lastdiscard)
    isempty(hand) && error("Empty hand held by $name")
    if mtype in cmdtypes && game.commandsvalid && mtype != "Wild"
        game.commandsvalid = false
        if mtype == "Draw Four"
            drawcardsfromdeck!(game, 4)
        elseif mtype == "Draw Two"
            drawcardsfromdeck!(game, 2)
        elseif mtype == "Skip"    # skip, no uno check
            logline("$name skips a turn.")
        elseif mtype == "Reverse"
            game.clockwise = !game.clockwise
            logline("Reverse: now going $(game.clockwise ? "clockwise." : "counter-clockwise.")")
            nextplayer!(game)
        end
        nextplayer!(game)
        return
    else  # num card, or command card is already used
        if isempty(indices)
            drawcardsfromdeck!(game)  # draw, then discard if drawn card is a match
            indices = playableindices(game)
            !isempty(indices) && discard!(game, first(indices))
        elseif !startswith(name, "Bot")  # not bot, so player moves
            logline("Click on a card to play.")
            flushchannel()
            while true
                item = take!(channel)
                if item isa Int && item in indices
                    discard!(game, item)
                    break
                end
                logline("That card is not playable.")
            end
        elseif nextsaiduno(game)  # bot might need to stop next player win
            sort!(hand, lt = (x, y) -> cardvalue(x) < cardvalue(y))
            indices = playableindices(game)
            discard!(game, last(indices))
        else # bot play any playable in hand
            discard!(game, rand(indices))
        end
    end
    length(hand) == 1 && logline("$name says UNO!")
    nextplayer!(game)
end

"""
    choosecolor!(game)
Choose a new game.colornow, automatically if a bot, via player choice if not a bot.
"""
function choosecolor!(game)
    logline("Player $(game.players[game.pnow].name) choosing color")
    hand = game.players[game.pnow].hand
    isempty(hand) && return rand(colors)
    if game.players[game.pnow].isabot
        game.colornow = preferredcolor(hand)
    else
        flushchannel()
        while true
            item = take!(channel)
            if item isa String && item in colors
                game.colornow = item
                break
            end
        end
    end
    logline("Current color is now $(game.colornow).")
end

#================  required documentation section ======================#

const unodocshtml = """
Official Rules For Uno Card Game
The aim of the game is to be the first player to score 500 points, achieved (usually over several rounds of play) by being the first to play all of one's own cards and scoring points for the cards still held by the other players.
The deck consists of 108 cards: four each of "Wild" and "Wild Draw Four", and 25 each of four colors (red, yellow, green, blue). Each color consists of one zero, two each of 1 through 9, and two each of "Skip", "Draw Two", and "Reverse". These last three types are known as "action cards".
To start a hand, seven cards are dealt to each player, and the top card of the remaining deck is flipped over and set aside to begin the discard pile. The player to the dealer's left plays first unless the first card on the discard pile is an action or Wild card (see below). On a player's turn, they must do one of the following:
*    play one card matching the discard in color, number, or symbol
*    play a Wild card, or a playable Wild Draw Four card (see restriction below)
*    draw the top card from the deck, then play it if possible
Cards are played by laying them face-up on top of the discard pile. Play proceeds clockwise around the table.
Action or Wild cards have the following effects:
===============================================================================================================================================================
Card            Effect when played from hand                                                                                                     Effect as first discard
---------------------------------------------------------------------------------------------------------------------------------------------------------------
Skip            Next player in sequence misses a turn                                                                                       Player to dealer's left misses a turn
Reverse         Order of play switches directions (clockwise to counterclockwise, or vice versa)            Dealer plays first; play proceeds counterclockwise
Draw Two        Next player in sequence draws two cards and misses a turn                                             Player to dealer's left draws two cards and misses a turn
Wild            Player declares the next color to be matched ; current color may be chosen                       Player to dealer's left declares the first color to be matched and plays a card in it
Wild Draw Four  Player declares the next color to be matched; next player in sequence draws four   Return card to the deck, shuffle, flip top card to start discard pile
A player who draws from the deck must either play or keep that card and may play no other card from their hand on that turn.
A player may play a Wild card at any time, even if that player has other playable cards.
A player may play a Wild Draw Four card only if that player has no cards matching the current color. The player may have cards of a different color matching the current number or symbol or a Wild card and still play the Wild Draw Four card.[5] A player who plays a Wild Draw Four may be challenged by the next player in sequence (see Penalties) to prove that their hand meets this condition.
If the entire deck is used during play, the top discard is set aside and the rest of the pile is shuffled to create a new deck. Play then proceeds normally.
It is illegal to trade cards of any sort with another player.
A player who plays their next-to-last-card must call "uno" as a warning to the other players.[6]
The first player to get rid of their last card ("going out") wins the hand and scores points for the cards held by the other players. Number cards count their face value, all action cards count 20, and Wild and Wild Draw Four cards count 50. If a Draw Two or Wild Draw Four card is played to go out, the next player in the sequence must draw the appropriate number of cards before the score is tallied.
The first player to score 500 points wins the game.
Penalties
=========
If a player does not call "uno" after laying down their next-to-last card and is caught before the next player in sequence takes a turn (i.e., plays a card from their hand, draws from the deck, or touches the discard pile), they must draw two cards as a penalty. If the player is not caught in time (subject to interpretation) or remembers to call "uno" before being caught, they suffer no penalty.
If a player plays a Wild Draw Four card, the following player can challenge its use. The player who used the Wild Draw Four must privately show their hand to the challenging player, in order to demonstrate that they had no matching colored cards. If the challenge is correct, then the challenged player draws four cards instead. If the challenge is wrong, then the challenger must draw six cards; the four cards they were already required to draw plus two more cards.
"""


#============ GUI interface section =======================#

const logwindow = GtkScrolledWindow()
const logtxt = GtkTextBuffer()
logtxt.text[String] = "Started a game of Uno."
const tview = GtkTextView(logtxt)
push!(logwindow, tview)

""" Lines are logged by extending logtxt at its start. """
function logline(txt)
    set_gtk_property!(logtxt, :text, txt * "\n" * get_gtk_property(logtxt, :text, String))
end

const cairocolor = Dict("Red" => colorant"red", "Yellow" => colorant"gold",
    "Green" => colorant"green", "Blue" => colorant"blue", "Wild" => colorant"black")

""" Draw a UnoCard as a rectangle with rounded corners. """
function cairocard(ctx, card, x0, y0, width, height, bcolor=colorant"white")
    fcolor = cairocolor[color(card)]
    set_source(ctx, fcolor)
    radius = (width + height) / 4
    set_line_width(ctx, radius / 5)
    x1 = x0 + width
    y1 = y0 + height
    if width / 2 < radius
        if height / 2 < radius
            move_to(ctx, x0, (y0 + y1) / 2)
            curve_to(ctx, x0 ,y0, x0, y0, (x0 + x1) / 2, y0)
            curve_to(ctx, x1, y0, x1, y0, x1, (y0 + y1) / 2)
            curve_to(ctx, x1, y1, x1, y1, (x1 + x0) / 2, y1)
            curve_to(ctx, x0, y1, x0, y1, x0, (y0 + y1) / 2)
        else
            move_to(ctx, x0, y0 + radius)
            curve_to(ctx, x0 ,y0, x0, y0, (x0 + x1) / 2, y0)
            curve_to(ctx, x1, y0, x1, y0, x1, y0 + radius)
            line_to(ctx, x1 , y1 - radius)
            curve_to(ctx, x1, y1, x1, y1, (x1 + x0) / 2, y1)
            curve_to(ctx, x0, y1, x0, y1, x0, y1 - radius)
        end
    else
        if rect_height / 2 < radius
            move_to(ctx, x0, (y0 + y1)  /2)
            curve_to(ctx, x0 , y0, x0 , y0, x0 + radius, y0)
            line_to(ctx, x1 - radius, y0)
            curve_to(ctx, x1, y0, x1, y0, x1, (y0 + y1) / 2)
            curve_to(ctx, x1, y1, x1, y1, x1 - radius, y1)
            line_to(ctx, x0 + radius, y1)
            curve_to(ctx, x0, y1, x0, y1, x0, (y0 + y1) / 2)
        else
            move_to(ctx, x0, y0 + radius)
            curve_to(ctx, x0 , y0, x0 , y0, x0 + radius, y0)
            line_to(ctx, x1 - radius, y0)
            curve_to(ctx, x1, y0, x1, y0, x1, y0 + radius)
            line_to(ctx, x1 , y1 - radius)
            curve_to(ctx, x1, y1, x1, y1, x1 - radius, y1)
            line_to(ctx, x0 + radius, y1)
            curve_to(ctx, x0, y1, x0, y1, x0, y1- radius)
        end
    end
    close_path(ctx)
    set_source(ctx, bcolor)
    fill_preserve(ctx)
    set_source(ctx, fcolor)
    stroke(ctx)
    move_to(ctx, x0 + width / 3, y0 + height / 3)
    txt = uppercase(type(card))
    if first(txt) in ['R', 'S', 'W']
        txt = string(first(txt))
    elseif first(txt) == 'D'
        txt = "D" * (txt[end] == 'O' ? "2" : "4")
    end
    show_text(ctx, txt)
    stroke(ctx)
end

""" Face down Uno cards are displayed as blank black rectangles with rounded corners. """
function cairodrawfacedowncard(ctx, x0, y0, width, height, bcolor=colorant"darkgray")
    cairocard(ctx, UnoCard("Wild", " "), x0, y0, width, height, bcolor)
end

"""
    UnoCardGameApp(w = 800, hcan = 600, hlog = 100)
Uno card game Gtk app. Draws game on a canvas, logs play on box below canvas.
"""
function UnoCardGameApp(w = 864, hcan = 700, hlog = 100)
    win = GtkWindow("Uno Card Game", w, hcan + hlog) |> (GtkFrame() |> (vbox = GtkBox(:v)))
    swin = GtkScrolledWindow()
    can = GtkCanvas(w, hcan)
    set_gtk_property!(can, :expand, true)
    push!(swin, can)
    push!(vbox, swin)
    push!(vbox, logwindow)  # from log section
    fontpointsize = w / 50
    cardpositions = Dict{Int, Vector{Int}}()
    colorpositions = Dict("Red" => [280, 435, 320, 475], "Yellow" => [340, 435, 380, 475],
        "Green" => [400, 435, 440, 475], "Blue" => [460, 435, 500, 475])
    challengeposition = [300, 492, 470, 482]
    game = UnoCardGameState()

    """ Draw the game board on the canvas including player's hand """
    @guarded Gtk.draw(can) do widget
        ctx = Gtk.getgc(can)
        height, width = Gtk.height(ctx), Gtk.width(ctx)
        select_font_face(ctx, "Courier", Cairo.FONT_SLANT_NORMAL, Cairo.FONT_WEIGHT_BOLD)
        set_font_size(ctx, fontpointsize)
        boardcolor = colorant"lightyellow"
        set_source(ctx, boardcolor)
        rectangle(ctx, 0, 0, width, height)
        fill(ctx)
        color = colorant"navy"
        set_source(ctx, color)
        move_to(ctx, 360, 400)
        show_text(ctx, game.players[1].name)
        stroke(ctx)
        move_to(ctx, 60, 300)
        show_text(ctx, game.players[2].name)
        stroke(ctx)
        move_to(ctx, 370, 60)
        show_text(ctx, game.players[3].name)
        stroke(ctx)
        move_to(ctx, 680, 300)
        show_text(ctx, game.players[4].name)
        stroke(ctx)
        cairocard(ctx, last(game.discardpile), 350, 240, 40, 80)
        cairodrawfacedowncard(ctx, 410, 240, 40, 80)
        for (i, p) in enumerate(colorpositions)
             set_source(ctx, cairocolor[first(p)])
             x0, y0, x1, y1 = last(p)
             rectangle(ctx, x0, y0, 40, 40)
             fill(ctx)
        end
        if challenge[end]
            set_source(ctx, colorant"black")
            move_to(ctx, challengeposition[1], challengeposition[2])
            show_text(ctx, "Challenge Draw Four")
            stroke(ctx)
        end
        hand = first(game.players).hand
        isempty(hand) && return
        nrow = (length(hand) + 15) ÷ 16
        for row in 1:nrow
            cards = hand[(row - 1) * 16 + 1 : min(length(hand), row * 16 - 1)]
            startx, starty = 40 + (16 - length(cards)) * 20, 500 + 85 * (row - 1)
            for (i, card) in enumerate(cards)
                idx, x0 = (row - 1) * 16 + i, startx + 50 * (i - 1)
                cardpositions[idx] = [x0, starty, x0 + 40, starty + 80]
                cairocard(ctx, card, x0, starty, 40, 80)
            end
        end
    end

    """ Gtk mouse callback: translates valid mouse clicks to a channel item """
    signal_connect(can, "button-press-event") do b, evt
        if challengeposition[1] < evt.x < challengeposition[3] &&
            challengeposition[4] < evt.y < challengeposition[2]
            challenge[begin] = true
            return
        end
        challenge[begin] = false
        for p in colorpositions
            x0, y0, x1, y1 = last(p)
            if x0 < evt.x < x1 && y0 < evt.y < y1
                push!(channel, first(p))
                return
            end
        end
        for p in cardpositions
            x0, y0, x1, y1 = last(p)
            if x0 < evt.x < x1 && y0 < evt.y < y1
                push!(channel, first(p))
                return
            end
        end
    end

    for n in 1:1000


        draw(can)
        Gtk.showall(win)
        while !any(i -> isempty(game.players[i].hand), 1:4)
            turn!(game)
            if startswith(game.players[game.pnow].name, "Play") &&
                type(game.discardpile[end]) == "Draw Four" && game.commandsvalid
                challenge[end] = true
                draw(can)
                show(can)
                info_dialog("Choose Challenge to challenge a Draw Four")
                sleep(5)
                challenge[end] = false
            end
            sleep(2)
            draw(can)
            show(can)
        end
        winner = findfirst(i -> isempty(game.players[i].hand), 1:length(game.players))
        if type(game.discardpile[end]) == "Draw Two"
        
        elseif type(game.discardpile[end]) == "Draw Four"

        end
        wonpoints = sum(x -> handscore(x.hand), game.players)
        game.players[winner].score += wonscore

        logline("Player $(game.players[winner].name) wins!")
        info_dialog(winner == nothing ? "No winner found." :
            "The WINNER of game $ is $(game.players[winner].name)!\n" *
            "Winner gains $wonpoints points.", win)
    end
    if any(x -> x.score >= 500, game.players)
    end
    game = nextgame(game)
end

UnoCardGameApp()

