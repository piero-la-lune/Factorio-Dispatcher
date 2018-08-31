local trainStopDispatcher = util.table.deepcopy(data.raw["train-stop"]["train-stop"])

trainStopDispatcher.name = "train-stop-dispatcher"
trainStopDispatcher.color = {r = 0, g = 0, b = 1, a = 1}
trainStopDispatcher.minable.result = "train-stop-dispatcher"

data:extend({
  trainStopDispatcher
})