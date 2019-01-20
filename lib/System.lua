local System = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Constants = require(script.Parent.Constants)

-- List of existing Arc instances
local SparksInstances = {}

-- Create superfolder for all particle/part folders
local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local MainFolder = PlayerGui:FindFirstChild(Constants.SPARKS_MAIN_FOLDER)
if not MainFolder then
	MainFolder = Instance.new("ScreenGui")
	MainFolder.Name = Constants.SPARKS_MAIN_FOLDER
	MainFolder.Parent = PlayerGui
end
MainFolder.ResetOnSpawn = false

local MainPartFolder = workspace:FindFirstChild(Constants.SPARKS_MAIN_FOLDER)
if not MainPartFolder then
	MainPartFolder = Instance.new("Folder")
	MainPartFolder.Name = Constants.SPARKS_MAIN_FOLDER
	MainPartFolder.Parent = workspace
end

-- Instancing method caching
local vec3 = Vector3.new
local vec2 = Vector2.new
local cframe = CFrame.new
local angles = CFrame.Angles

-- Frequently used instances caching
local zeroVector = vec3(0, 0, 0)
local uz = vec3(0,0,1)
local ux = vec3(1,0,0)

-- Math functions/constants caching
local random = math.random
local floor = math.floor
local acos = math.acos
local rad = math.rad
local min = math.min
local max = math.max
local abs = math.abs
local twopi = math.pi * 2.0
local dot = zeroVector.Dot
local cross = zeroVector.Cross

local autoThrottleRatio = 0.5 -- Current auto-throttling rate
local throttleDistanceModifier = 60 -- Studs distance from camera at which distance-throttling will start
local segmentPerArc = 12 -- Current number of segments per arc (lower number = better performance)

-- Tracking variables for auto-throttling
local frameCount = 0
local frameTick = tick()

-- I don't even know why I precompute this, but whatever
local difSegmentsPerArc = Constants.SEGMENT_PER_ARC_MAX - Constants.SEGMENT_PER_ARC_MIN
local difDistanceModifier = Constants.THROTTLE_DISTANCE_MODIFIER_MAX - Constants.THROTTLE_DISTANCE_MODIFIER_MIN

-- Internal method for updating the arcs for a heartbeat
-- (mostly courtesy of AllYourBlox)

local function updateArc(self)
	-- Combined brightness of the arcs on the current render frame, used to update point light
	local totalBrightness = 0

	-- Table cache references:
	local step = self.step
	local totalSteps = self.totalSteps
	local brightness = self.brightness
	local axisKeyPoints0 = self.axisKeyPoints0
	local axisKeyPoints1 = self.axisKeyPoints1
	local pathT0 = self.pathT0
	local pathT1 = self.pathT1

	-- Loop from 1 to floor(self.arcRenderAmount):
	for _ = 1, self.arcRenderAmount do

		-- Cache references for current arc:
		local arc = self.arc
		local amountSegments

		-- If this is the first step in the animation of an arc, generate the start and end paths
		if step[arc] == 0 then

			-- Determine the resolution in segments for this new arc:
			amountSegments = floor(max(2, segmentPerArc * min(1, Constants.SEGMENT_THROTTLING_DISTANCE / self.distance)))
			self.amountSegments[arc] = amountSegments

			-- Randomize how many tween steps this arc will last, with random roll for
			-- chance of an occasional long-duration hot wandering arc
			local RARE_CHANCE = (random() < Constants.RARE_CHANCE) and 1 or 0
			totalSteps[arc] = (Constants.TWEEN_STEPS_MIN + floor(random()*(Constants.TWEEN_STEPS_MAX-Constants.TWEEN_STEPS_MIN))) * (1 + RARE_CHANCE * (Constants.RARE_CHANCE_DURATION_MULT-1))
			brightness[arc] = (RARE_CHANCE > 0) and 1 or random()

			-- Midpoint radius of the arc "envelope" is proportional to the length of the arc
			local maxRadius = (0.025 * (totalSteps[arc]/Constants.TWEEN_STEPS_MAX) + 0.05 * (1+random()))

			-- Random start direction of the first arc segment
			local segmentAngle = random() * twopi

			-- Pick random points along the axis for the discs where arc path points lie
			axisKeyPoints0[1] = 0
			axisKeyPoints1[1] = 0
			for i = 2, amountSegments do
				axisKeyPoints0[i] = axisKeyPoints0[i-1] + 1 + random() * Constants.SEGMENT_MINMAX_RATIO
				axisKeyPoints1[i] = axisKeyPoints1[i-1] + 1 + random() * Constants.SEGMENT_MINMAX_RATIO
			end

			-- Normalize the points to the range [0,1]
			for i = 2, amountSegments do
				axisKeyPoints0[i] = axisKeyPoints0[i] / axisKeyPoints0[amountSegments]
				axisKeyPoints1[i] = axisKeyPoints1[i] / axisKeyPoints1[amountSegments]
			end

			-- Calculate the path points
			local ur, r

			-- pathT0
			for i = 1, amountSegments do
				ur = angles(segmentAngle, 0, 0) * uz

				-- r is the distance of the path point from the axis line segment, and this formula is the shape of the envelope
				-- of the arc (0 at the endpoints, maxRadius at the middle, with clamping so that long arcs don't get too wide)
				r = min(maxRadius * 0.5, ( 0.5 - abs(0.5-axisKeyPoints0[i]) ) * 4 * maxRadius * (0.25 + 0.75*random()))
				pathT0[arc][i] = axisKeyPoints0[i] * ux + r * ur
				segmentAngle = segmentAngle + random(-1,1) * Constants.SEGMENT_ANGULAR_CHANGE_MAX
			end

			-- pathT1
			-- A long duration arc will lerp from a narrower arc to a wider one, end here refers to t=1 animation end state
			local endRadiusMult = 1.0 + 0.5 * (totalSteps[arc]-Constants.TWEEN_STEPS_MIN)/(Constants.TWEEN_STEPS_MAX*Constants.RARE_CHANCE_DURATION_MULT-Constants.TWEEN_STEPS_MIN)
			for i = 1, amountSegments do
				ur = angles(segmentAngle, 0, 0) * uz
				r = min(maxRadius * 0.5 * endRadiusMult, ( 0.5 - abs(0.5-axisKeyPoints1[i]) ) * 4 * maxRadius * (0.25 + 0.75*random())) -- The arc envelope
				pathT1[arc][i] = axisKeyPoints1[i] * ux + r * ur
				segmentAngle = segmentAngle + random(-1,1) * Constants.SEGMENT_ANGULAR_CHANGE_MAX
				self.segments[i + (arc-1) * Constants.SEGMENT_PER_ARC_MAX].Parent = self.segmentsFolder
			end

			-- Unparent unneeded segments from the game hierarchy to improve performance:
			for i = amountSegments + 1, Constants.SEGMENT_PER_ARC_MAX do
				self.segments[i + (arc-1) * Constants.SEGMENT_PER_ARC_MAX].Parent = nil
			end

		else
			-- Existing arc, just import the segment count:
			amountSegments = self.amountSegments[arc]
		end

		-- Initialize values:
		totalBrightness = 0
		local prevEndpoint = zeroVector
		local t = step[arc] / (totalSteps[arc]-1)
		totalBrightness = totalBrightness + brightness[arc]

		-- Lerp color towards white based on brightness:
		local color = self.color:lerp(self.topColor, brightness[arc])

		-- Fatness of arc based on its brightness:
		local fatness = (brightness[arc] > 0.98) and 3.2 or 1.6

		-- Relative position of camera w.r.t. this effect:
		local camPos = self.cframe:inverse() * workspace.CurrentCamera.CFrame.p

		-- Loop over segment count for this arc, and simply update animation:
		for i = 1, amountSegments do

			-- Lerp from pathT0 to pathT1, adjusted by arcLength:
			local endpoint = self.length * (t * pathT1[arc][i] + (1-t) * pathT0[arc][i])

			-- Get image texture handle for this segment:
			local imgAdornment = self.segments[i + (arc-1) * Constants.SEGMENT_PER_ARC_MAX]

			-- Offset from last point to current one
			local diff = endpoint - prevEndpoint

			-- Calculate position and up/left/front vectors
			local po = (prevEndpoint + endpoint)/2
			local up = diff.unit
			local lf = cross(camPos - po, up).unit
			local fr = cross(lf, up).unit

			-- Update handle
			imgAdornment.Size = vec2(fatness, diff.magnitude + fatness/16)
			imgAdornment.Color3 = color
			imgAdornment.CFrame = cframe(
				po.x, po.y, po.z,
				lf.x, up.x, fr.x,
				lf.y, up.y, fr.y,
				lf.z, up.z, fr.z
			)

			-- Update prevEndpoint
			prevEndpoint = endpoint

		end

		-- Update step count for current arc and then move to next arc to update
		step[arc] = (step[arc] + 1) % totalSteps[arc]
		self.arc = (arc % self.numArcs) + 1

	end

	-- Update brightness of light in emitter part
	self.partFolder.Emitter.PointLight.Brightness = totalBrightness / self.numArcs

	-- Subtract integer part from the amount of arcs to be updated
	self.arcRenderAmount = self.arcRenderAmount % 1
end

-- Global update loop on heartbeat
-- (for performance / user-friendliness reasons, it is better to do a global loop over all
-- objects at Heartbeat rather than exposing an API method to update individual objects)
RunService.Heartbeat:connect(
    function()
        -- Cache camera-related values and references
        local camera = workspace.CurrentCamera
        local camPos = camera.CFrame.p
        local look = camera.CFrame.lookVector
        -- 1.25 is a fudge factor to allow for width of arc and viewing of light pool without seeing animation frozen
        local fov = 1.25 * rad(camera.FieldOfView * camera.ViewportSize.x / camera.ViewportSize.y) / 2.0

        -- Check if objects are on/off-screen
        for v, _ in pairs(SparksInstances) do
            local camToSource = v.cframe.p - camPos
            local camToDrain = v.cframe * vec3(v.length, 0, 0) - camPos

            -- Check if on-screen:
            if acos(dot(camToSource.unit, look)) > fov and acos(dot(camToDrain.unit, look)) > fov then
                -- Else, make visible and reparent, if not already done
                -- Not on-screen, turn invisible and unparent if not already
                if v.visible then
                    v.visible = false
                    v.segmentsFolder.Parent = nil
                end
            elseif not v.visible then
                v.visible = true
                v.segmentsFolder.Parent = MainFolder
            end

            -- Set average distance to camera for throttling purposes
            v.distance = (camToSource.magnitude + camToDrain.magnitude) / 2
        end

        -- Check if objects should be updated and do so
        for v, _ in pairs(SparksInstances) do
            -- Only update enabled and visible objects
            if v.visible then
                -- Update CFrame/Size of instances if object values were changed
                if v.changed then
                    v.partFolder.Source.CFrame = v.cframe
                    v.partFolder.Emitter.Size = vec3(0.2, 0.2, v.length)
                    v.partFolder.Emitter.CFrame = cframe(v.cframe * vec3(v.length / 2, 0, 0), v.cframe.p)
                    v.changed = false
                end

                -- Update amount of arcs that can be rendered in this step (can be real, not just integer)
                if v.distance < Constants.MAX_DISTANCE then
                    v.arcRenderAmount =
                        v.arcRenderAmount +
                        min(v.numArcs / 3, Constants.ARCS_PER_UPDATE * min(1, throttleDistanceModifier / v.distance))
                    updateArc(v)
                end
            end
        end

        -- Increase frame count
        frameCount = frameCount + 1

        -- Calculate time since last throttling check
        local deltaTime = tick() - frameTick

        -- Check if auto-throttling window has passed
        if deltaTime > Constants.AUTO_THROTTLE_FRAME_INTERVAL then
            -- Update auto-throttling ratio based on observed FPS w.r.t. target FPS
            autoThrottleRatio =
                max(
                0,
				min(1, autoThrottleRatio + Constants.AUTO_THROTTLE_INCREMENT
					* (frameCount / deltaTime - Constants.AUTO_THROTTLE_TARGET))
            )

            -- Update variables dependent on auto-throttling rate
            segmentPerArc = floor(Constants.SEGMENT_PER_ARC_MIN + (difSegmentsPerArc * autoThrottleRatio) + 0.5)
			throttleDistanceModifier = Constants.THROTTLE_DISTANCE_MODIFIER_MIN
				+ (difDistanceModifier * autoThrottleRatio)

            -- Reset tracking variables
            frameCount = 0
            frameTick = tick()
        end
    end
)

-- Adding an arc to the running system
function System.add(arc)
	if not SparksInstances[arc] then
		SparksInstances[arc] = true
		arc.segmentsFolder.Parent = MainFolder
		arc.partFolder.Parent = MainPartFolder
	end
end

-- Removing an arc from the running system
function System.remove(arc)
	if SparksInstances[arc] then
		SparksInstances[arc] = nil
		arc.segmentsFolder.Parent = nil
		arc.partFolder.Parent = nil
	end
end

return System