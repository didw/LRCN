--
--  Copyright (c) 2014, Facebook, Inc.
--  All rights reserved.
--
--  This source code is licensed under the BSD-style license found in the
--  LICENSE file in the root directory of this source tree. An additional grant
--  of patent rights can be found in the PATENTS file in the same directory.
--
require 'image'
if opt.dataType == 'avi' then
   require 'ffmpeg'
end
paths.dofile('dataset.lua')
paths.dofile('util.lua')

-- This file contains the data-loading logic and details.
-- It is run by each data-loader thread.
------------------------------------------

-- a cache file of the training metadata (if doesnt exist, will be created)
local trainCache = paths.concat(opt.cache, 'trainCache.t7')
local testCache = paths.concat(opt.cache, 'testCache.t7')
local meanstdCache = paths.concat(opt.cache, 'meanstdCache.t7')

-- Check for existence of opt.data
if not os.execute('cd ' .. opt.data) then
    error(("could not chdir to '%s'"):format(opt.data))
end

local loadSize   = {3, opt.imageSize, opt.imageSize}
local sampleSize = {3, opt.cropSize, opt.cropSize}


local function loadImage(path)
   local input = image.load(path, 3, 'float')
   -- find the smaller dimension, and resize it to loadSize (while keeping aspect ratio)
   if input:size(3) < input:size(2) then
      input = image.scale(input, loadSize[2], loadSize[3] * input:size(2) / input:size(3))
   else
      input = image.scale(input, loadSize[2] * input:size(3) / input:size(2), loadSize[3])
   end
   return input
end

local function getPath(path, idx)
   local res="";
   local i = 0
   for splt in string.gmatch(path, "([^.]+)") do
      if i == 1 then
         splt = string.format( "%04d", splt - idx )
      end
      if i == 0 then
         res = splt
      else
         res = res .. "." .. splt
      end
      i = i + 1
   end
   return res
end

local function loadVideo(videopath, depth)
   inputs = {}
   local vid = ffmpeg.Video{path=videopath, silent=true}
   local frames = vid:totensor{}
   if frames:size(1) < depth then
      print(videopath, frames:size(1))
   end
   local idx = torch.random(1, frames:size(1)-depth+1)
   for i=idx,idx+depth-1 do
      -- find the smaller dimension, and resize it to loadSize (while keeping aspect ratio)
      local input = frames[i]
      if input:size(3) < input:size(2) then
         input = image.scale(input, loadSize[2], loadSize[3] * input:size(2) / input:size(3))
      else
         input = image.scale(input, loadSize[2] * input:size(3) / input:size(2), loadSize[3])
      end
      table.insert(inputs, input)
   end
   return inputs
end

-- channel-wise mean and std. Calculate or load them from disk later in the script.
local mean,std
--------------------------------------------------------------------------------
--[[
   Section 1: Create a train data loader (trainLoader),
   which does class-balanced sampling from the dataset and does a random crop
--]]

-- function to load the image, jitter it appropriately (random crops etc.)
local trainHook = function(self, path, depth)
   collectgarbage()
   local outs = {}
   local inputs
   if opt.dataType == 'avi' then
      inputs = loadVideo(path, depth)
   end
   for i=1,depth do
      local input
      if opt.dataType == 'avi' then 
         input = inputs[i]
      elseif opt.dataType == 'jpg' then
         input = loadImage(getPath(path, depth - i))
      end
      local iW = input:size(3)
      local iH = input:size(2)
   
      -- do random crop
      local oW = sampleSize[3]
      local oH = sampleSize[2]
      local w1 = math.ceil(torch.uniform(1e-2, iW-oW))
      local h1 = math.ceil(torch.uniform(1e-2, iH-oH))
      local out = image.crop(input, w1, h1, w1 + oW, h1 + oH)
      assert(out:size(3) == oW)
      assert(out:size(2) == oH)
      -- do hflip with probability 0.5
      if torch.uniform() > 0.5 then out = image.hflip(out) end
      -- mean/std
      for c=1,3 do -- channels
         if mean then out[{{c},{},{}}]:add(-mean[c]) end
         if std then out[{{c},{},{}}]:div(std[c]) end
      end
      table.insert(outs, out)
   end
   return outs
end

if paths.filep(trainCache) then
   print('Loading train metadata from cache')
   trainLoader = torch.load(trainCache)
   trainLoader.sampleHookTrain = trainHook
   assert(trainLoader.paths[1] == paths.concat(opt.data, 'train'),
          'cached files dont have the same path as opt.data. Remove your cached files at: '
             .. trainCache .. ' and rerun the program')
else
   print('Creating train metadata')
   trainLoader = dataLoader{
      paths = {paths.concat(opt.data, 'train')},
      loadSize = loadSize,
      sampleSize = sampleSize,
      stride = opt.depthSize / 2,
      depth = opt.depthSize,
      split = 100,
      verbose = true
   }
   torch.save(trainCache, trainLoader)
   trainLoader.sampleHookTrain = trainHook
end
collectgarbage()

-- do some sanity checks on trainLoader
do
   local class = trainLoader.imageClass
   local nClasses = #trainLoader.classes
   assert(class:max() <= nClasses, "class logic has error")
   assert(class:min() >= 1, "class logic has error")

end

-- End of train loader section
--------------------------------------------------------------------------------
--[[
   Section 2: Create a test data loader (testLoader),
   which can iterate over the test set and returns an image's
--]]

-- function to load the image
local testHook = function(self, path, depth)
   collectgarbage()
   local outs = {}
   local inputs
   if opt.dataType == 'avi' then
      inputs = loadVideo(path, depth)
   end
   for i=1,depth do
      local input
      if opt.dataTeyp == 'avi' then
         input = inputs[i]
      elseif opt.dataType == 'jpg' then
         input = loadImage(getPath(path, depth-i))
      end
      local iW = input:size(3)
      local iH = input:size(2)
      local oW = sampleSize[3]
      local oH = sampleSize[2]
      local w1 = math.ceil((iW-oW)/2)
      local h1 = math.ceil((iH-oH)/2)
      local out = image.crop(input, w1, h1, w1+oW, h1+oH) -- center patch
      -- mean/std
      for c=1,3 do -- channels
         if mean then out[{{c},{},{}}]:add(-mean[c]) end
         if std then out[{{c},{},{}}]:div(std[c]) end
      end
      table.insert(outs, out)
   end
   return outs
end

if paths.filep(testCache) then
   print('Loading test metadata from cache')
   testLoader = torch.load(testCache)
   testLoader.sampleHookTest = testHook
   assert(testLoader.paths[1] == paths.concat(opt.data, 'val'),
          'cached files dont have the same path as opt.data. Remove your cached files at: '
             .. testCache .. ' and rerun the program')
else
   print('Creating test metadata')
   testLoader = dataLoader{
      paths = {paths.concat(opt.data, 'val')},
      loadSize = loadSize,
      sampleSize = sampleSize,
      stride = opt.depthSize / 2,
      depth = opt.depthSize,
      split = 0,
      verbose = true,
      forceClasses = trainLoader.classes -- force consistent class indices between trainLoader and testLoader
   }
   torch.save(testCache, testLoader)
   testLoader.sampleHookTest = testHook
end
collectgarbage()
-- End of test loader section

-- Estimate the per-channel mean/std (so that the loaders can normalize appropriately)
if paths.filep(meanstdCache) then
   local meanstd = torch.load(meanstdCache)
   mean = meanstd.mean
   std = meanstd.std
   print('Loaded mean and std from cache.')
else
   local tm = torch.Timer()
   local nSamples = 10000
   print('Estimating the mean (per-channel, shared for all pixels) over ' .. nSamples .. ' randomly sampled training images')
   local meanEstimate = {0,0,0}
   for i=1,nSamples do
      local img = trainLoader:sample(1, 1)[1][1]
      for j=1,3 do
         meanEstimate[j] = meanEstimate[j] + img[j]:mean()
      end
   end
   for j=1,3 do
      meanEstimate[j] = meanEstimate[j] / nSamples
   end
   mean = meanEstimate

   print('Estimating the std (per-channel, shared for all pixels) over ' .. nSamples .. ' randomly sampled training images')
   local stdEstimate = {0,0,0}
   for i=1,nSamples do
      local img = trainLoader:sample(1, 1)[1][1]
      for j=1,3 do
         stdEstimate[j] = stdEstimate[j] + img[j]:std()
      end
   end
   for j=1,3 do
      stdEstimate[j] = stdEstimate[j] / nSamples
   end
   std = stdEstimate

   local cache = {}
   cache.mean = mean
   cache.std = std
   torch.save(meanstdCache, cache)
   print('Time to estimate:', tm:time().real)
end
