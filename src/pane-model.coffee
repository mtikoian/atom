{find, compact, clone, extend} = require 'underscore-plus'
{dirname} = require 'path'
{Model, Sequence} = require 'theorist'
Serializable = require 'serializable'
PaneAxisModel = require './pane-axis-model'
Pane = null

module.exports =
class PaneModel extends Model
  atom.deserializers.add(this)
  Serializable.includeInto(this)

  @properties
    container: null
    activeItem: null
    focused: false

  @behavior 'active', ->
    @$container
      .flatMapLatest((container) -> container?.$activePane)
      .map((activePane) => activePane is this)
      .distinctUntilChanged()

  constructor: (params) ->
    super

    @items = Sequence.fromArray(params?.items ? [])
    @activeItem ?= @items[0]

    @subscribe @items.onEach (item) =>
      if typeof item.on is 'function'
        @subscribe item, 'destroyed', => @removeItem(item)

    @subscribe @items.onRemoval (item, index) =>
      @unsubscribe item if typeof item.on is 'function'

    @makeActive() if params?.active

  serializeParams: ->
    items: compact(@items.map((item) -> item.serialize?()))
    activeItemUri: @activeItem?.getUri?()
    focused: @focused
    active: @active

  deserializeParams: (params) ->
    {items, activeItemUri} = params
    params.items = items.map (itemState) -> atom.deserializers.deserialize(itemState)
    params.activeItem = find params.items, (item) -> item.getUri?() is activeItemUri
    params

  getViewClass: -> Pane ?= require './pane'

  isActive: -> @active

  focus: ->
    @focused = true
    @makeActive()

  blur: ->
    @focused = false

  makeActive: -> @container?.activePane = this

  getPanes: -> [this]

  # Public: Returns all contained views.
  getItems: ->
    @items.slice()

  # Public: Returns the item at the specified index.
  itemAtIndex: (index) ->
    @items[index]

  # Public: Switches to the next contained item.
  showNextItem: ->
    index = @getActiveItemIndex()
    if index < @items.length - 1
      @showItemAtIndex(index + 1)
    else
      @showItemAtIndex(0)

  # Public: Switches to the previous contained item.
  showPreviousItem: ->
    index = @getActiveItemIndex()
    if index > 0
      @showItemAtIndex(index - 1)
    else
      @showItemAtIndex(@items.length - 1)

  # Public: Returns the index of the currently active item.
  getActiveItemIndex: ->
    @items.indexOf(@activeItem)

  # Public: Switch to the item associated with the given index.
  showItemAtIndex: (index) ->
    @showItem(@itemAtIndex(index))

  # Public: Focuses the given item.
  showItem: (item) ->
    if item?
      @addItem(item)
      @activeItem = item

  # Public: Add an additional item at the specified index.
  addItem: (item, index=@getActiveItemIndex() + 1) ->
    return if item in @items

    @items.splice(index, 0, item)
    @emit 'item-added', item, index
    item

  # Public:
  removeItem: (item, destroying) ->
    index = @items.indexOf(item)
    @removeItemAtIndex(index, destroying) if index >= 0

  # Public: Just remove the item at the given index.
  removeItemAtIndex: (index, destroying) ->
    item = @items[index]
    @showNextItem() if item is @activeItem and @items.length > 1
    @items.splice(index, 1)
    @emit 'item-removed', item, index, destroying
    @destroy() if @items.length is 0

  # Public: Moves the given item to a the new index.
  moveItem: (item, newIndex) ->
    oldIndex = @items.indexOf(item)
    @items.splice(oldIndex, 1)
    @items.splice(newIndex, 0, item)
    @emit 'item-moved', item, newIndex

  # Public: Moves the given item to another pane.
  moveItemToPane: (item, pane, index) ->
    pane.addItem(item, index)
    @removeItem(item)

  # Public: Remove the currently active item.
  destroyActiveItem: ->
    @destroyItem(@activeItem)
    false

  # Public: Remove the specified item.
  destroyItem: (item, options) ->
    @emit 'before-item-destroyed', item
    if @promptToSaveItem(item)
      @emit 'item-destroyed', item
      @removeItem(item, true)
      item.destroy?()
      true
    else
      false

  # Public: Remove and delete all items.
  destroyItems: ->
    @destroyItem(item) for item in @getItems()

  # Public: Remove and delete all but the currently focused item.
  destroyInactiveItems: ->
    @destroyItem(item) for item in @getItems() when item isnt @activeItem

  # Private: Called by model superclass
  destroyed: ->
    @container.makeNextPaneActive() if @isActive()
    item.destroy?() for item in @items.slice()

  # Public: Prompt the user to save the given item.
  promptToSaveItem: (item) ->
    return true unless item.shouldPromptToSave?()

    uri = item.getUri()
    chosen = atom.confirm
      message: "'#{item.getTitle?() ? item.getUri()}' has changes, do you want to save them?"
      detailedMessage: "Your changes will be lost if you close this item without saving."
      buttons: ["Save", "Cancel", "Don't Save"]

    switch chosen
      when 0 then @saveItem(item, -> true)
      when 1 then false
      when 2 then true

  # Public: Saves the currently focused item.
  saveActiveItem: ->
    @saveItem(@activeItem)

  # Public: Save and prompt for path for the currently focused item.
  saveActiveItemAs: ->
    @saveItemAs(@activeItem)

  # Public: Saves the specified item and call the next action when complete.
  saveItem: (item, nextAction) ->
    if item.getUri?()
      item.save?()
      nextAction?()
    else
      @saveItemAs(item, nextAction)

  # Public: Prompts for path and then saves the specified item. Upon completion
  # it also calls the next action.
  saveItemAs: (item, nextAction) ->
    return unless item.saveAs?

    itemPath = item.getPath?()
    itemPath = dirname(itemPath) if itemPath
    path = atom.showSaveDialogSync(itemPath)
    if path
      item.saveAs(path)
      nextAction?()

  # Public: Saves all items in this pane.
  saveItems: ->
    @saveItem(item) for item in @getItems()

  # Public: Finds the first item that matches the given uri.
  itemForUri: (uri) ->
    find @items, (item) -> item.getUri?() is uri

  # Public: Focuses the first item that matches the given uri.
  showItemForUri: (uri) ->
    if item = @itemForUri(uri)
      @showItem(item)
      true
    else
      false

  # Private:
  copyActiveItem: ->
    @activeItem.copy?() ? atom.deserializers.deserialize(@activeItem.serialize())

  splitLeft: (params) ->
    @split('horizontal', 'before', params)

  splitRight: (params) ->
    @split('horizontal', 'after', params)

  splitUp: (params) ->
    @split('vertical', 'before', params)

  splitDown: (params) ->
    @split('vertical', 'after', params)

  split: (orientation, side, params) ->
    if @parent.orientation isnt orientation
      @parent.replaceChild(this, new PaneAxisModel({@container, orientation, children: [this]}))

    newPane = new @constructor(extend({focused: true}, params))
    switch side
      when 'before' then @parent.insertChildBefore(this, newPane)
      when 'after' then @parent.insertChildAfter(this, newPane)

    newPane.makeActive()
    newPane
