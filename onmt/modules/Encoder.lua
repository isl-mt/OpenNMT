--[[ Encoder is a unidirectional Sequencer used for the source language.

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
local Encoder, parent = torch.class('onmt.Encoder', 'onmt.Sequencer')

--[[ Construct an encoder layer.

Parameters:

  * `inputNetwork` - input module.
  * `rnn` - recurrent module.
]]
function Encoder:__init(inputNetwork, rnn, opt)
  self.rnn = rnn
  self.inputNet = inputNetwork

  self.args = {}
  self.args.rnnSize = self.rnn.outputSize
  self.args.numEffectiveLayers = self.rnn.numEffectiveLayers
  self.args.layers = self.rnn.layers
  self.args.dropout = opt.dropout
  self.args.recDropout = opt.recDropout

  parent.__init(self, self:_buildModel())

  self:resetPreallocation()
end

--[[ Return a new Encoder using the serialized data `pretrained`. ]]
function Encoder.load(pretrained)
  local self = torch.factory('onmt.Encoder')()

  self.args = pretrained.args
  parent.__init(self, pretrained.modules[1])

  self:resetPreallocation()

  return self
end

--[[ Return data to serialize. ]]
function Encoder:serialize()
  return {
    name = 'Encoder',
    modules = self.modules,
    args = self.args
  }
end

function Encoder:resetPreallocation()
  -- Prototype for preallocated hidden and cell states.
  self.stateProto = torch.Tensor()

  -- Prototype for preallocated output gradients.
  self.gradOutputProto = torch.Tensor()

  -- Prototype for preallocated context vector.
  self.contextProto = torch.Tensor()
  
  -- For mask allocation
  if self.args.layers > 1 then
		self.inputMaskProto = torch.Tensor()
  end

  self.recurrentMaskProto = torch.Tensor()
		
	-- maybe an output mask as well ? 
  
end

function Encoder:maskPadding()
  self.maskPad = true
end

--[[ Build one time-step of an encoder

Returns: An nn-graph mapping

  $${(c^1_{t-1}, h^1_{t-1}, .., c^L_{t-1}, h^L_{t-1}, x_t) =>
  (c^1_{t}, h^1_{t}, .., c^L_{t}, h^L_{t})}$$

  Where $$c^l$$ and $$h^l$$ are the hidden and cell states at each layer,
  $$x_t$$ is a sparse word to lookup.
--]]
function Encoder:_buildModel()
  local inputs = {}
  local states = {}

  -- Inputs are previous layers first.
  for _ = 1, self.args.numEffectiveLayers do
    local h0 = nn.Identity()() -- batchSize x rnnSize
    table.insert(inputs, h0)
    table.insert(states, h0)
  end
  
  if self.args.layers > 1 then
		local inputMask = nn.Identity()()
		table.insert(inputs, inputMask)
		table.insert(states, inputMask)
	end
	
	local recurrentMask = nn.Identity()()
  table.insert(states, recurrentMask)
  table.insert(inputs, recurrentMask) 
  

  -- Input word.
  local x = nn.Identity()() -- batchSize
  table.insert(inputs, x)

  -- Compute input network.
  local input = self.inputNet(x)
  table.insert(states, input)

  -- Forward states and input into the RNN.
  local outputs = self.rnn(states)
  return nn.gModule(inputs, { outputs })
end

function Encoder:generateDropoutMask(batchSize)
	
	local inputMask
	if self.inputMaskProto then
		inputMask = onmt.utils.Tensor.reuseTensor(self.inputMaskProto,
                                                { batchSize, self.args.layers-1, self.args.rnnSize }):fill(1)
	end
	
	local recurrentMask = onmt.utils.Tensor.reuseTensor(self.recurrentMaskProto,
                                                { batchSize, self.args.layers, self.args.rnnSize }):fill(1)   
	
	-- if training then sample from a Bernoulli distribution
	if self.train then
		
		if inputMask then
			inputMask:bernoulli(1 - self.args.dropout)
			inputMask:div(1 - self.args.dropout)
		end
		
		recurrentMask:bernoulli(1 - self.args.recDropout)
		recurrentMask:div(1 - self.args.recDropout)
	end
	
	local masks = {}
  --~ masks[1] = inputMask
  --~ masks[2] = recurrentMask                        
	
	if inputMask then
		table.insert(masks, inputMask)
	end
	table.insert(masks, recurrentMask)
	
	return masks
end

--[[Compute the context representation of an input.

Parameters:

  * `batch` - as defined in batch.lua.

Returns:

  1. - final hidden states
  2. - context matrix H
--]]
function Encoder:forward(batch)

  -- TODO: Change `batch` to `input`.

  local finalStates
  local outputSize = self.args.rnnSize
  
  -- generate masks based on batch size
  -- same masks are used throughout the sequence forward pass
  local masks = self:generateDropoutMask(batch.size)

  if self.statesProto == nil then
    self.statesProto = onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                                         self.stateProto,
                                                         { batch.size, outputSize })
  end

  -- Make initial states h_0.
  local states = onmt.utils.Tensor.reuseTensorTable(self.statesProto, { batch.size, outputSize })

  -- Preallocated output matrix.
  local context = onmt.utils.Tensor.reuseTensor(self.contextProto,
                                                { batch.size, batch.sourceLength, outputSize })

	-- 
  if self.maskPad and not batch.sourceImergenputPadLeft then
    finalStates = onmt.utils.Tensor.recursiveClone(states)
  end
  
  if self.train then
    self.inputs = {}
  end

  -- Act like nn.Sequential and call each clone in a feed-forward
  -- fashion.
  for t = 1, batch.sourceLength do

    -- Construct "inputs". Prev states come first then source.
    local inputs = {}
    onmt.utils.Table.append(inputs, states)
    
    -- masks for variational RNN 
    onmt.utils.Table.append(inputs, masks)
    
    -- input at time t (word index or word + feature indices)
    table.insert(inputs, batch:getSourceInput(t))

    if self.train then
      -- Remember inputs for the backward pass.
      self.inputs[t] = inputs
    end
    states = self:net(t):forward(inputs)

    -- Make sure it always returns table.
    if type(states) ~= "table" then states = { states } end

    -- Special case padding.
    if self.maskPad then
      for b = 1, batch.size do
        if (batch.sourceInputPadLeft and t <= batch.sourceLength - batch.sourceSize[b])
					or (not batch.sourceInputPadLeft and t > batch.sourceSize[b]) then
					for j = 1, #states do
						states[j][b]:zero()
					end
        elseif not batch.sourceInputPadLeft and t == batch.sourceSize[b] then
          for j = 1, #states do
            finalStates[j][b]:copy(states[j][b])
          end
        end
      end
    end

    -- Copy output (h^L_t = states[#states]) to context.
    context[{{}, t}]:copy(states[#states])
  end

  if finalStates == nil then
    finalStates = states
  end

  return finalStates, context
end

--[[ Backward pass (only called during training)

  Parameters:

  * `batch` - must be same as for forward
  * `gradStatesOutput` gradient of loss wrt last state - this can be null if states are not used
  * `gradContextOutput` - gradient of loss wrt full context.

  Returns: `gradInputs` of input network.
--]]
function Encoder:backward(batch, gradStatesOutput, gradContextOutput)
  -- TODO: change this to (input, gradOutput) as in nngraph.
  local outputSize = self.args.rnnSize
  if self.gradOutputsProto == nil then
    self.gradOutputsProto = onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                                              self.gradOutputProto,
                                                              { batch.size, outputSize })
  end

  local gradStatesInput
  if gradStatesOutput then
    gradStatesInput = onmt.utils.Tensor.copyTensorTable(self.gradOutputsProto, gradStatesOutput)
  else
    -- if gradStatesOutput is not defined - start with empty tensor
    gradStatesInput = onmt.utils.Tensor.reuseTensorTable(self.gradOutputsProto, { batch.size, outputSize })
  end

  local gradInputs = {}

  for t = batch.sourceLength, 1, -1 do
    -- Add context gradients to last hidden states gradients.
    gradStatesInput[#gradStatesInput]:add(gradContextOutput[{{}, t}])
    
    -- nngraph does not accept table of size 1.
		local timestepGradOutput = #gradStatesInput > 1 and gradStatesInput or gradStatesInput[1]

    local gradInput = self:net(t):backward(self.inputs[t], timestepGradOutput)

    -- Prepare next encoder output gradients.
    for i = 1, #gradStatesInput do
      gradStatesInput[i]:copy(gradInput[i])
    end

    -- Gather gradients of all user inputs.
    gradInputs[t] = {}
    for i = #gradStatesInput + 1, #gradInput do
      table.insert(gradInputs[t], gradInput[i])
    end

    if #gradInputs[t] == 1 then
      gradInputs[t] = gradInputs[t][1]
    end
  end
  -- TODO: make these names clearer.
  -- Useful if input came from another network.
  return gradInputs

end
