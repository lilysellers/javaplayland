debugging = true
log = (mesg) ->  console.log mesg if debugging
if not deepcopy?
    deepcopy = (src) -> $.extend(true, {},src)

class window.GameManager
    constructor: (@environment) ->
        @config = @environment.description

        @editorDiv = 'codeEditor'
        @visualDiv = 'gameVisual'
        @setUpGame()

    setUpGame: ->
        ###
            Sets up everything for the game to run.
        ###
        @gameDiv = jQuery @environment.gamediv
        editdiv = document.createElement("div")
        vis = document.createElement("div")

        $(editdiv).attr({'id':@editorDiv,'class':'code_editor'})
        $(editdiv).css({width:'35%',height:'90%','position':'absolute','top':'5%','left':'5%'})

        $(vis).attr({'id':@visualDiv,'class':'game_visual'})
        $(vis).css({width:'35%',height:'90%','position':'absolute','top':'5%','right':'5%'})

        @gameDiv.append(editdiv)
        @gameDiv.append '<button id="refOpen" style="position:absolute;top:40%;right:45%">Reference</button>'
        @gameDiv.append '<button id="gmOp" style="position:absolute;top:48%;right:45%">Game Map</button>'
        $(editdiv).append '<button id="compileAndRun">Go</button>'
        $(editdiv).append '<button id="resetState">Reset</button>'
        @gameDiv.append(vis)

        @codeEditor = new EditorManager @editorDiv, @config.editor, @config.code
        @interpreter = new CodeInterpreter @config.editor.commands

        @environment.visualMaster.container.id = @visualDiv
        @visual = new GameVisual @environment.visualMaster, @environment.frameRate
        @addEventListeners()
        return

    startGame: (waitForCode) ->
        if not waitForCode?
            waitForCode = false

        for character, val of @config.game.characters
            # Load starting positions into visual config
            @config.visual.characters[character].x = val.x
            @config.visual.characters[character].y = val.y
            if val.dir?
                @config.visual.characters[character].dir = val.dir

        @visual.startGame @config.visual
        @gameState = new MapGameState @, waitForCode
        @commandMap = new MapGameCommands @gameState
        return

    gameWon: (score, stars) ->
        log "Game Won: #{@environment.key}"

        player = @environment.player
        if player.games[@environment.key]?
            if player.games[@environment.key].hiscore? > score
                score = player.games[@environment.key].hiscore

            if player.games[@environment.key].stars? > stars
                stars = player.games[@environment.key].stars

        @environment.codeland.storeGameCompletionData @environment.key, {
            hiscore : score,
            stars : stars,
            passed : true
        }
        @finishGame()
        return

    finishGame: ->
        @codeEditor = null
        @interpreter = null
        @visual = null
        return

    addEventListeners: ->
        jQuery('#compileAndRun').click @runStudentCode
        jQuery('#resetState').click @reset
        jQuery('#refOpen').click InitFloat
        jQuery('#gmOp').click codeland.showMap

        return

    reset: =>
        @codeEditor.resetEditor()
        @startGame false
        return

    runStudentCode: =>
        @interpreter.scanText @codeEditor.getStudentCode()
        @startGame true
        @interpreter.executeCommands @commandMap
        return

class MapGameState
    clockHandle = null
    #<--DIRECTIONS-->
    #       ^
    #       0
    #   < 3 4 1 >
    #       2
    #       v
    constructor: (@gameManager, waitForCode) ->
        @gameConfig = deepcopy @gameManager.config.game
        @visual = @gameManager.visual
        @score = 0
        @stars = 0
        @protagonist = @gameConfig.characters.protagonist
        @target = @gameConfig.characters.gflag
        @tick = 0

        for name, character of @gameConfig.characters
            if character.AI?
                @_stand character
                for command in character.AI.normal
                    @executeAICommand character, command

        if clockHandle?
            clearInterval clockHandle
        clockHandle = setInterval @clock, 17
        @startedGame = false
        if not waitForCode then @start()
        return

    executeAICommand: (character, command) ->
        @character = character
        for arg, index in command.arguments
            if arg in ["character", "protagonist"]
                command.arguments[index] = this[arg]
        this[command.command].apply @, command.arguments
        @character = null
        return

    clock: =>
        @tick++
        if @startedGame and @tick % 30 == 0
            protDoneMoving = false
            for name, character of @gameConfig.characters
                if not character.moves?
                    continue

                nextMove = false
                if character.moves.length > 0
                    command = character.moves.splice(0, 1)[0]
                    worked = command.exec()

                    if character.AI?
                        if not worked
                            if character.AI.failed[command.key]?
                                for aiCommand in character.AI.failed[command.key]
                                    @executeAICommand character, aiCommand
                        else
                            nextMove = true
                else
                    nextMove = true

                if nextMove and character.AI?
                    for aiCommand in character.AI.normal
                        @executeAICommand character, aiCommand

                else if character is @protagonist
                    protDoneMoving = true
            if protDoneMoving and @protagonist.x == @target.x and @protagonist.y == @target.y
                    @gameWon()
        @visual.getFrame @gameManager.config.visual, @tick
        return

    start: ->
        @_stand @protagonist
        @startedGame = true
        return

    _stand: (character) ->
        if not character?
            character = @protagonist

        character.moves.push {
            key: 'stand',
            exec: ((char) ->
                @visual.changeState char.index, 4
                return).bind @, character
        }
        return

    move: (steps, character) ->
        if not character?
            character = @protagonist

        if character.moves.length > 0 and
          character.moves[character.moves.length - 1].key == 'stand'
            character.moves.pop()
        character.moves.push {
            key: 'startMove',
            exec: ((char) ->
                return @_move(char)
                ).bind @, character
        }
        for i in [1...steps] by 1
            @_moving(character)
        return

    _moving: (character) ->
        if not character?
            character = @protagonist

        character.moves.push {
            key: 'moving',
            exec: ((char) ->
                return @_move(char)
                ).bind @, character
        }

    _move: (character) ->
        if not character?
            character = @protagonist

        # Top Left: 0,0
        moved = false
        [newx, newy] = @computeStepInDirection(character.dir,
            character.x, character.y)
        hitEvent = @checkInBounds(newx, newy)
        if !hitEvent
            @visual.changeState character.index, character.dir
            character.x = newx
            character.y = newy
            moved = true
        else
            @visual.changeState character.index, 4
        return moved

    turn: (direction, character) ->
        if not character?
            character = @protagonist

        if character.moves.length > 0 and
          character.moves[character.moves.length - 1].key == 'stand'
            character.moves.pop()

        character.moves.push {
            key: 'turn',
            exec: ((dir, char) ->
                @_turn dir, char
                return).bind @, direction, character
        }
        @_stand character
        return

    turnRight: (character) ->
        if not character?
            character = @protagonist

        if character.moves.length > 0 and
          character.moves[character.moves.length - 1].key == 'stand'
            character.moves.pop()

        character.moves.push {
            key: 'turn',
            exec: ((char) ->
                @_turn ((char.dir + 1) % 4), char
                return).bind @, character
        }
        @_stand(character)
        return

    turnLeft: (character) ->
        if not character?
            character = @protagonist

        if character.moves.length > 0 and
          character.moves[character.moves.length - 1].key == 'stand'
            character.moves.pop()

        character.moves.push {
            key: 'turn',
            exec: ((char) ->
                @_turn ((char.dir + 3) % 4), char
                return).bind @, character
        }
        @_stand(character)
        return

    _turn: (direction, character) ->
        if not character?
            character = @protagonist

        character.dir = direction
        @visual.charFace character.index, character.dir
        @visual.changeState character.index, 4
        return

    gameWon: ->
        clearInterval clockHandle
        @stars += 1
        @score += 5
        @gameManager.gameWon @score, @stars
        return

    checkInBounds: (playerX, playerY) ->
        canNotMove = false
        if playerX < 0 or playerX >= @gameManager.config.visual.grid.gridX\
          or playerY < 0 or playerY >= @gameManager.config.visual.grid.gridY
            # Player is out of bounds of grid.
            canNotMove = true
        return canNotMove

    computeStepInDirection: (direction, currentX, currentY) ->
        # Bits are more fun that lookup tables or a switch
        # sign is positive 1 for South 10, and East 01, -1 for North 00, and West 11
        [sign, isEastOrWest] = [-1 + ((direction + 1) & 2), direction & 1]
        if isEastOrWest
            newx = currentX + sign
            newy = currentY
        unless isEastOrWest
            newx = currentX
            newy = currentY + sign

        return [newx, newy]

class MapGameCommands
    constructor: (@gameState) ->
        return

    finishedParsingStartGame: ->
        @gameState.start()
        return

    go: (steps) =>
        steps = 1 if steps is undefined
        # log "Go #{steps} steps."
        @gameState.move steps

    turn: (dir) =>
        # log "turn '#{dir}'"
        return if dir is undefined
        d = $.inArray(dir, ['N','E','S','W'])
        if d >= 0
            @gameState.turn d
        else
            d = $.inArray(dir, ['North','East','South','West'])
            if d >= 0
                @gameState.turn d
            else if !isNaN d
                @gameState.turn (4 + dir % 4) % 4
        return

    turnRight: =>
        # log "turnRight"
        @gameState.turnRight()
        return

    turnLeft: =>
        # log "turnLeft"
        @gameState.turnLeft()
        return

    turnAndGo: (direction, steps) =>
        # log "turnAndGo #{direction} #{steps}"
        @turn direction
        @go steps
        return

    goNorth: (steps) => @turnAndGo 0, steps
    goEast:  (steps) => @turnAndGo 1, steps
    goWest:  (steps) => @turnAndGo 2, steps
    goSouth: (steps) => @turnAndGo 3, steps

    # used in sequence4
    mysteryA: => @goEast 4
    mysteryB: => @goSouth 1
    mysteryC: => @goWest 2
