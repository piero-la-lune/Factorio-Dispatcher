data:extend({
  {
    type = "technology",
    name = "dispatcher",
    icon_size = 128,
    icon = "__Dispatcher__/graphics/technology/dispatcher.png",
    effects =
    {
      {
        type = "unlock-recipe",
        recipe = "train-stop-dispatcher"
      }
    },
    prerequisites = {"automated-rail-transportation", "advanced-electronics"},
    unit =
    {
      count = 100,
      ingredients =
      {
        {"science-pack-1", 1},
        {"science-pack-2", 1}
      },
      time = 30
    },
    order = "c-g-aa",
  }
})