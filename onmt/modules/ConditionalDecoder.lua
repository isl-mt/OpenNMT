--[[ Unit to decode a sequence of output tokens.

     .      .      .             .
     |      |      |             |
    h_1 => h_2 => h_3 => ... => h_n
     |      |      |             |
     .      .      .             .
     |      |      |             |
    h_1 => h_2 => h_3 => ... => h_n
     |      |      |             |
     |      |      |             |
    x_1    x_2    x_3           x_n

Inherits from [onmt.Sequencer](onmt+modules+Sequencer).

--]]
local ConditionalDecoder, parent = torch.class('onmt.ConditionalDecoder', 'onmt.Sequencer')


--[[ Construct a ConditionalDecoder layer.

Parameters:

  * `inputNetwork` - input nn module.
  * `rnn` - recurrent module, such as [onmt.LSTM](onmt+modules+LSTM).
  * `generator` - optional, an output [onmt.Generator](onmt+modules+Generator).
  * `inputFeed` - bool, enable input feeding.
--]]
function ConditionalDecoder:__init(inputNetwork, rnn, generator, attention, inputFeed, coverage)
  self.rnn = rnn
  self.inputNet = inputNetwork

  self.args = {}
  self.args.rnnSize = self.rnn.outputSize
  self.args.numEffectiveLayers = self.rnn.numEffectiveLayers

  self.args.inputIndex = {}
  self.args.outputIndex = {}

  -- Input feeding means the ConditionalDecoder takes an extra
  -- vector each time representing the attention at the
  -- previous step.
  self.args.inputFeed = inputFeed
  self.args.coverageSize = coverage
  
  -- backward compatibility with older models
  if self.args.coverageSize == nil then 
		self.args.coverageSize = 0
	end
	
	if self.args.attention == nil then
		self.args.attention = 'global'
	end
  
  
  -- Attention type
  self.args.attention = attention

  parent.__init(self, self:_buildModel())

  -- The generator use the output of the ConditionalDecoder sequencer to generate the
  -- likelihoods over the target vocabulary.
  self.generator = generator
  self:add(self.generator)

  self:resetPreallocation()
end

--[[ Return a new ConditionalDecoder using the serialized data `pretrained`. ]]
function ConditionalDecoder.load(pretrained)
  local self = torch.factory('onmt.ConditionalDecoder')()

  self.args = pretrained.args

  parent.__init(self, pretrained.modules[1])
  self.generator = pretrained.modules[2]
  self:add(self.generator)

  self:resetPreallocation()

  return self
end

--[[ Return data to serialize. ]]
function ConditionalDecoder:serialize()
  return {
    modules = self.modules,
    args = self.args
  }
end

function ConditionalDecoder:resetPreallocation()
  if self.args.inputFeed then
    self.inputFeedProto = torch.Tensor()
  end
  
  -- backward compatibility with older models
  if self.args.coverageSize == nil then
		self.args.coverageSize = 0
	end
  
  if self.args.coverageSize > 0 then
		self.coverageInputProto = torch.Tensor()
		self.gradCoverageProto = torch.Tensor()
  end

  -- Prototype for preallocated hidden and cell states.
  self.stateProto = torch.Tensor()

  -- Prototype for preallocated output gradients.
  self.gradOutputProto = torch.Tensor()

  -- Prototype for preallocated context gradient.
  self.gradContextProto = torch.Tensor()
  
  self.gradHiddenProto = torch.Tensor()
  
  self.samplingProto = torch.Tensor()
end

--[[ Build a default one time-step of the ConditionalDecoder

Returns: An nn-graph mapping

  $${(c^1_{t-1}, h^1_{t-1}, .., c^L_{t-1}, h^L_{t-1}, x_t, con/H, if) =>
  (c^1_{t}, h^1_{t}, .., c^L_{t}, h^L_{t}, a)}$$

  Where ${c^l}$ and ${h^l}$ are the hidden and cell states at each layer,
  ${x_t}$ is a sparse word to lookup,
  ${con/H}$ is the context/source hidden states for attention,
  ${if}$ is the input feeding, and
  ${a}$ is the context vector computed at this timestep.
--]]
function ConditionalDecoder:_buildModel()
  local inputs = {}
  local states = {}

  -- Inputs are previous layers first.
  for _ = 1, self.args.numEffectiveLayers do
    local h0 = nn.Identity()() -- batchSize x rnnSize
    table.insert(inputs, h0)
    table.insert(states, h0)
  end

  local x = nn.Identity()() -- batchSize
  table.insert(inputs, x)
  self.args.inputIndex.x = #inputs

  local context = nn.Identity()() -- batchSize x sourceLength x rnnSize
  table.insert(inputs, context)
  self.args.inputIndex.context = #inputs
  
  local inputFeed
  if self.args.inputFeed then
    inputFeed = nn.Identity()() -- batchSize x rnnSize
    table.insert(inputs, inputFeed)
    self.args.inputIndex.inputFeed = #inputs
  end
  
  local coverageVector
  if self.args.coverageSize > 0 then
	_G.logger:info(" * Maintaining context coverage with GRU-based model ")
	coverageVector = nn.Identity()() -- batchSize x coverageSize
	table.insert(inputs, coverageVector)
	self.args.inputIndex.coverage = #inputs
  end

  -- Compute the input network.
  local embedding = self.inputNet(x)
  
  
  local input = embedding
  -- If set, concatenate previous ConditionalDecoder output.
  if self.args.inputFeed then
    input = nn.JoinTable(2)({input, inputFeed})
  end
  table.insert(states, input)

  -- Forward states and input into the RNN.
  local outputs = self.rnn(states)

  -- The output of a subgraph is a node: split it to access the last RNN output.
  outputs = { outputs:split(self.args.numEffectiveLayers) }

  -- Compute the attention here using h^L as query.
  
  local attnLayer
  
  if self.args.coverageSize == 0 then
	  if self.args.attention == 'global' then
		attnLayer = onmt.GlobalAttention(self.args.rnnSize)
	  elseif self.args.attention == 'cgate' then
		attnLayer = onmt.ContextGateAttention(self.args.rnnSize)
	  end
  else
	  attnLayer = onmt.CoverageAttention(self.args.rnnSize, self.args.coverageSize)
  end
  
  attnLayer.name = 'ConditionalDecoderAttn'
  
  -- prepare input for the attention module
  local attnInput = {outputs[#outputs], context}
  if self.args.coverageSize > 0 then
	table.insert(attnInput, coverageVector)
  end
  
  local attnOutput = attnLayer(attnInput)
  
  
  local nextCoverage
  if self.args.coverageSize > 0 then
	attnOutput = {attnOutput:split(2)}
	nextCoverage = attnOutput[2]
	attnOutput = attnOutput[1]
	table.insert(outputs, nextCoverage)
  end
  
  if self.rnn.dropout > 0 then
    attnOutput = nn.Dropout(self.rnn.dropout)(attnOutput)
  end
  table.insert(outputs, attnOutput)
  return nn.gModule(inputs, outputs)
end

--[[ Mask padding means that the attention-layer is constrained to
  give zero-weight to padding. This is done by storing a reference
  to the softmax attention-layer.

  Parameters:

  * See  [onmt.MaskedSoftmax](onmt+modules+MaskedSoftmax).
--]]
function ConditionalDecoder:maskPadding(sourceSizes, sourceLength)
  if not self.decoderAttn then
    self.network:apply(function (layer)
      if layer.name == 'decoderAttn' then
        self.decoderAttn = layer
      end
    end)
  end

  self.decoderAttn:replace(function(module)
    if module.name == 'softmaxAttn' then
      local mod
      if sourceSizes ~= nil then
        mod = onmt.MaskedSoftmax(sourceSizes, sourceLength)
      else
        mod = nn.SoftMax()
      end

      mod.name = 'softmaxAttn'
      mod:type(module._type)
      self.softmaxAttn = mod
      return mod
    else
      return module
    end
  end)
end

--[[ Run one step of the decoder.

Parameters:

  * `input` - input to be passed to inputNetwork.
  * `prevStates` - stack of hidden states (batch x layers*model x rnnSize)
  * `context` - encoder output (batch x n x rnnSize)
  * `prevOut` - previous distribution (batch x #words)
  * `t` - current timestep

Returns:

 1. `out` - Top-layer hidden state.
 2. `states` - All states.
--]]
function ConditionalDecoder:forwardOne(input, prevStates, context, prevOut, prevCoverage, t)
  local inputs = {}

  -- Create RNN input (see sequencer.lua `buildNetwork('dec')`).
  onmt.utils.Table.append(inputs, prevStates)
  table.insert(inputs, input)
  table.insert(inputs, context)
  local inputSize
  if torch.type(input) == 'table' then
    inputSize = input[1]:size(1)
  else
    inputSize = input:size(1)
  end

  if self.args.inputFeed then
    if prevOut == nil then
      table.insert(inputs, onmt.utils.Tensor.reuseTensor(self.inputFeedProto,
                                                         { inputSize, self.args.rnnSize }))
    else
      table.insert(inputs, prevOut)
    end
  end
  
  if self.args.coverageSize > 0 then
	if prevCoverage == nil then -- initialize the coverage vector as zero
		prevCoverage = onmt.utils.Tensor.reuseTensor(self.coverageInputProto, {inputSize, context:size(2), self.args.coverageSize})
	end
	table.insert(inputs, prevCoverage)
  end

  -- Remember inputs for the backward pass.
  if self.train then
    self.inputs[t] = inputs
  end
  
  --~ print(self.inputs[t])
  
  local outputs = self:net(t):forward(inputs)

  -- Make sure decoder always returns table.
  if type(outputs) ~= "table" then outputs = { outputs } end

  local out = outputs[#outputs]
  local states = {}
  
  local nOutputs = 1
  local nextCoverage = nil
  if self.args.coverageSize > 0 then
	nOutputs = 2
	nextCoverage = outputs[#outputs - 1] -- update the coverage vector
  end
  
  for i = 1, #outputs - nOutputs do
    table.insert(states, outputs[i])
  end

  return out, nextCoverage, states
end

--[[Compute all forward steps.

  Parameters:

  * `batch` - `Batch` object
  * `encoderStates` -
  * `context` -
  * `func` - Calls `func(out, t)` each timestep.
--]]

function ConditionalDecoder:forwardAndApply(batch, encoderStates, context, func)
  -- TODO: Make this a private method.

  if self.statesProto == nil then
    self.statesProto = onmt.utils.Tensor.initTensorTable(#encoderStates,
                                                         self.stateProto,
                                                         { batch.size, self.args.rnnSize })
  end

  local states = onmt.utils.Tensor.copyTensorTable(self.statesProto, encoderStates)

  local prevOut, prevCoverage

  for t = 1, batch.targetLength do
    prevOut, prevCoverage, states = self:forwardOne(batch:getTargetInput(t), states, context, prevOut, prevCoverage, t)
    func(prevOut, t)
  end
end

--[[Compute all forward steps.

  Parameters:

  * `batch` - a `Batch` object.
  * `encoderStates` - a batch of initial decoder states (optional) [0]
  * `context` - the context to apply attention to.

  Returns: Table of top hidden state for each timestep.
--]]
function ConditionalDecoder:forward(batch, encoderStates, context)
  encoderStates = encoderStates
    or onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                         onmt.utils.Cuda.convert(torch.Tensor()),
                                         { batch.size, self.args.rnnSize })
  if self.train then
    self.inputs = {}
  end

  local outputs = {}

  self:forwardAndApply(batch, encoderStates, context, function (out)
    table.insert(outputs, out)
  end)

  return outputs
end

--[[ Compute the backward update.

Parameters:

  * `batch` - a `Batch` object
  * `outputs` - expected outputs
  * `criterion` - a single target criterion object

  Note: This code runs both the standard backward and criterion forward/backward.
  It returns both the gradInputs and the loss.
  -- ]]
function ConditionalDecoder:backward(batch, outputs, criterion)
  if self.gradOutputsProto == nil then
    self.gradOutputsProto = onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                                              self.gradOutputProto,
                                                              { batch.size, self.args.rnnSize })
  end

  local gradStatesInput = onmt.utils.Tensor.reuseTensorTable(self.gradOutputsProto,
                                                             { batch.size, self.args.rnnSize })
  local gradContextInput = onmt.utils.Tensor.reuseTensor(self.gradContextProto,
                                                         { batch.size, batch.sourceLength, self.args.rnnSize })
                                                         
  if self.args.coverageSize > 0 then
	local gradCoverageOutput = onmt.utils.Tensor.reuseTensor(self.gradCoverageProto, {batch.size, batch.sourceLength, self.args.coverageSize})
	table.insert(gradStatesInput, gradCoverageOutput)
  end
  
  local gradHiddenProto = onmt.utils.Tensor.reuseTensor(self.gradHiddenProto, {batch.size, self.args.rnnSize})
  table.insert(gradStatesInput, gradHiddenProto)

  local loss = 0

  for t = batch.targetLength, 1, -1 do
    -- Compute decoder output gradients.
    -- Note: This would typically be in the forward pass.
    local pred = self.generator:forward(outputs[t])
    local output = batch:getTargetOutput(t)

    loss = loss + criterion:forward(pred, output)

    -- Compute the criterion gradient.
    local genGradOut = criterion:backward(pred, output)
    for j = 1, #genGradOut do
      genGradOut[j]:div(batch.totalSize)
    end

    -- Compute the final layer gradient.
    local decGradOut = self.generator:backward(outputs[t], genGradOut)
    gradStatesInput[#gradStatesInput]:add(decGradOut)

    -- Compute the standard backward.
    local gradInput = self:net(t):backward(self.inputs[t], gradStatesInput)

    -- Accumulate encoder output gradients.
    gradContextInput:add(gradInput[self.args.inputIndex.context])
    gradStatesInput[#gradStatesInput]:zero()

    -- Accumulate previous output gradients with input feeding gradients.
    if self.args.inputFeed and t > 1 then
      gradStatesInput[#gradStatesInput]:add(gradInput[self.args.inputIndex.inputFeed])
    end
    
    -- Accumulate previous coverage gradients
    if self.args.coverageSize > 0  then
	  --~ gradStatesInput[#gradStatesInput-1]:zero()
	  --~ gradStatesInput[#gradStatesInput-1]:add(gradInput[self.args.inputIndex.coverage])
	  gradStatesInput[#gradStatesInput-1] = gradInput[self.args.inputIndex.coverage]
    end

    -- Prepare next decoder output gradients.
    for i = 1, #self.statesProto do
      gradStatesInput[i]:copy(gradInput[i])
    end
  end

  return gradStatesInput, gradContextInput, loss
end

--[[ Compute the loss on a batch.

Parameters:

  * `batch` - a `Batch` to score.
  * `encoderStates` - initialization of decoder.
  * `context` - the attention context.
  * `criterion` - a pointwise criterion.

--]]
function ConditionalDecoder:computeLoss(batch, encoderStates, context, criterion)
  encoderStates = encoderStates
    or onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                         onmt.utils.Cuda.convert(torch.Tensor()),
                                         { batch.size, self.args.rnnSize })

  local loss = 0
  self:forwardAndApply(batch, encoderStates, context, function (out, t)
    local pred = self.generator:forward(out)
    local output = batch:getTargetOutput(t)
    loss = loss + criterion:forward(pred, output)
  end)

  return loss
end


--[[ Compute the score of a batch.

Parameters:

  * `batch` - a `Batch` to score.
  * `encoderStates` - initialization of decoder.
  * `context` - the attention context.

--]]
function ConditionalDecoder:computeScore(batch, encoderStates, context)
  encoderStates = encoderStates
    or onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                         onmt.utils.Cuda.convert(torch.Tensor()),
                                         { batch.size, self.args.rnnSize })

  local score = {}

  self:forwardAndApply(batch, encoderStates, context, function (out, t)
    local pred = self.generator:forward(out)
    for b = 1, batch.size do
      if t <= batch.targetSize[b] then
        score[b] = (score[b] or 0) + pred[1][b][batch.targetOutput[t][b]]
      end
    end
  end)

  return score
end

function ConditionalDecoder:sampleBatch(batch, encoderStates, context, maxLength, argmax)
	
	maxLength = maxLength or onmt.Constants.MAX_TARGET_LENGTH
	
	local sampled = onmt.utils.Tensor.reuseTensor(self.samplingProto, {maxLength, batch.size})
	
	local sampledSeq = onmt.utils.Cuda.convert(sampled)

	sampledSeq:fill(onmt.Constants.PAD) -- fill with PAD first
	sampledSeq[1]:fill(onmt.Constants.BOS) -- <s> at the beginning
	
	if self.statesProto == nil then
		self.statesProto = onmt.utils.Tensor.initTensorTable(#encoderStates,
                                                         self.stateProto,
                                                         { batch.size, self.args.rnnSize })
	end
	
	local states = onmt.utils.Tensor.copyTensorTable(self.statesProto, encoderStates)
	
	local prevOut, prevCoverage
	
	local realMaxLength = maxLength-- Avoid wasting time in sampling too many PAD
	
	local stopTensor
	
	-- Start sampling
	for t = 1, maxLength do
		local input
		
		if t == 1 then
			input = sampledSeq[t]
		else
			input = sampledSeq[t - 1]
		end
		
		prevOut, prevCoverage, states = self:forwardOne(input, states, context, prevOut, prevCoverage, t)
		
		
		local pred = self.generator:forward(prevOut)[1] -- because generator returns a table
		pred:exp() -- exp to get the distribution
		
		-- get the argmax ( we are using greedy sampling )
		local _, indx = pred:max(2)
		
		sampledSeq[t]:copy(indx:resize(batch.size))
			
		-- if input is EOS or PAD then sample is PAD too
		local compare = torch.eq(input, onmt.Constants.EOS)
		compare:add(torch.eq(input, onmt.Constants.PAD))
		
		sampledSeq[t]:maskedFill(compare, onmt.Constants.PAD)
		
		-- check if all tensors have ended with EOS
		if stopTensor then
			stopTensor:add(torch.eq(sampledSeq[t], onmt.Constants.EOS))
		else
			stopTensor = torch.eq(sampledSeq[t], onmt.Constants.EOS)
		end
		
		-- if all of them are finished then we stop the RNN from running
		if stopTensor:sum() == batch.size then
			realMaxLength = t
			break
		end
	end
	
	sampledSeq = sampledSeq:narrow(1, 1, realMaxLength)  
	return sampledSeq
end
