data:extend({
  {
    type = "item-subgroup",
    name = "dispatcher-signals",
    group = "signals",
    order = "g"
  },
  {
    type = "virtual-signal",
    name = "dispatcher-station",
    icons =
    {
      {icon = "__Dispatcher__/graphics/icons/shape_square.png"},
      {icon = "__Dispatcher__/graphics/icons/dispatcher.png"}
    },
    icon_size = 32, icon_mipmaps = 1,
    subgroup = "dispatcher-signals",
    order = "a-a"
  },
})