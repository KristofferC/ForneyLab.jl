############################################
# GainAdditionNode
############################################
# Description:
#   Gain-addition node: out = A*in1 + in2
#   Combines the node functions of the FixedGainNode
#   and the AdditionNode for computational efficiency.
#
#            | in1
#            |
#        ____|____
#        |   v   |
#        |  [A]  |
#        |   |   |
#    in2 |   v   | out
#   -----|->[+]--|---->
#        |_______|
#
#   f(in1,in2,out) = δ(out - A*in1 - in2)
#
# Interfaces:
#   1 i[:in1], 2 i[:in2], 3 i[:out]
#
# Construction:
#   GainAdditionNode([1.0], id=:my_node)
#
############################################
export GainAdditionNode

type GainAdditionNode <: Node
    A::Array{Float64}
    id::Symbol
    interfaces::Array{Interface,1}
    i::Dict{Symbol,Interface}
    A_inv::Array{Float64, 2} # holds pre-computed inv(A) if possible

    function GainAdditionNode(A::Union{Array{Float64},Float64}=1.0; id=generateNodeId(GainAdditionNode))
        self = new(ensureMatrix(deepcopy(A)), id, Array(Interface, 3), Dict{Symbol,Interface}())
        addNode!(currentGraph(), self)

        for (iface_index, iface_handle) in enumerate([:in1, :in2, :out])
            self.i[iface_handle] = self.interfaces[iface_index] = Interface(self)
        end

        # Precompute inverse of A
        try self.A_inv = inv(self.A) end

        return self
    end
end

isDeterministic(::GainAdditionNode) = true


############################################
# GaussianDistribution methods
############################################

# Forward to OUT
function sumProduct!(   node::GainAdditionNode,
                        outbound_interface_index::Int,
                        in1::Message{GaussianDistribution},
                        in2::Message{GaussianDistribution},
                        ::Void)
    (outbound_interface_index == 3) || error("Invalid outbound interface id $(outbound_interface_index), on $(typeof(node)) $(node.id).")
    (isProper(in1.payload) && isProper(in2.payload)) || error("Improper input distributions are not supported")
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], GaussianDistribution).payload
    dist_1 = ensureParameters!(in1.payload, (:m, :V))
    dist_2 = ensureParameters!(in2.payload, (:m, :V))
    dist_out.m = dist_2.m + node.A[1,1]*dist_1.m
    dist_out.V = dist_2.V + node.A[1,1]^2 * dist_1.V
    dist_out.xi = dist_out.W = NaN

    return (:gain_addition_gaussian_forward,
            node.interfaces[outbound_interface_index].message)
end

# Backward to IN2
function sumProduct!(   node::GainAdditionNode,
                        outbound_interface_index::Int,
                        in1::Message{GaussianDistribution},
                        ::Void,
                        out::Message{GaussianDistribution})
    (outbound_interface_index == 2) || error("Invalid outbound interface id $(outbound_interface_index), on $(typeof(node)) $(node.id).")
    (isProper(in1.payload) && isProper(out.payload)) || error("Improper input distributions are not supported")
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], GaussianDistribution).payload
    dist_1 = ensureParameters!(in1.payload, (:m, :V))
    dist_3 = ensureParameters!(out.payload, (:m, :V))
    dist_out.m  = dist_3.m - node.A[1,1]*dist_1.m
    dist_out.V  = dist_3.V + node.A[1,1]^2 * dist_1.V
    dist_out.xi = dist_out.W = NaN

    return (:gain_addition_gaussian_backward_in2,
            node.interfaces[outbound_interface_index].message)
end

# Backward to IN1
function sumProduct!(   node::GainAdditionNode,
                        outbound_interface_index::Int,
                        ::Void,
                        in2::Message{GaussianDistribution},
                        out::Message{GaussianDistribution})
    (outbound_interface_index == 1) || error("Invalid outbound interface id $(outbound_interface_index), on $(typeof(node)) $(node.id).")
    (isProper(in2.payload) && isProper(out.payload)) || error("Improper input distributions are not supported")
    dist_temp = GaussianDistribution()

    dist_temp.m = ensureParameters!(out.payload, (:m, :V)).m - ensureParameters!(in2.payload, (:m, :V)).m
    dist_temp.V = in2.payload.V + out.payload.V
    dist_temp.W = dist_temp.xi = NaN

    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], GaussianDistribution).payload
    ensureParameters!(dist_temp, (:xi, :W))
    dist_out.xi = node.A[1,1] * dist_temp.xi
    dist_out.W = (node.A[1,1])^2 * dist_temp.W
    dist_out.m = dist_out.V = NaN

    return (:gain_addition_gaussian_backward_in1,
        node.interfaces[outbound_interface_index].message)
end


############################################
# MvGaussianDistribution methods
############################################

# Rule set for forward propagation ({in1,in2}-->out)
# From: Korl (2005), "A Factor graph approach to signal modelling, system identification and filtering", Table 4.1
forwardGainAdditionMRule{T<:Number}(A::Array{T, 2}, m_x::Array{T, 1}, m_y::Array{T, 1}) = m_x + A*m_y
forwardGainAdditionVRule{T<:Number}(A::Array{T, 2}, V_x::Array{T, 2}, V_y::Array{T, 2}) = V_x + A*V_y*A'
forwardGainAdditionWRule{T<:Number}(A::Array{T, 2}, W_x::Array{T, 2}, W_y::Array{T, 2}) = W_x - W_x * A * inv(W_y+A'*W_x*A) * A' * W_x
forwardGainAdditionXiRule{T<:Number}(A::Array{T, 2}, xi_x::Array{T, 1}, xi_y::Array{T, 1}, W_x::Array{T, 2}, W_y::Array{T, 2}) = xi_x + W_x*A*inv(W_y+A'*W_x*A)*(xi_y-A'*xi_x)

# Rule set for backward propagation ({in1,out}-->in2)
# From: Korl (2005), "A Factor graph approach to signal modelling, system identification and filtering", Table 4.1
backwardIn2GainAdditionMRule{T<:Number}(A::Array{T, 2}, m_y::Array{T, 1}, m_z::Array{T, 1}) = m_z - A*m_y
backwardIn2GainAdditionVRule{T<:Number}(A::Array{T, 2}, V_y::Array{T, 2}, V_z::Array{T, 2}) = V_z + A*V_y*A'
backwardIn2GainAdditionWRule{T<:Number}(A::Array{T, 2}, W_y::Array{T, 2}, W_z::Array{T, 2}) = W_z - W_z * A * inv(W_y+A'*W_z*A) * A' * W_z
backwardIn2GainAdditionXiRule{T<:Number}(A::Array{T, 2}, xi_y::Array{T, 1}, xi_z::Array{T, 1}, W_y::Array{T, 2}, W_z::Array{T, 2}) = xi_z - W_z*A*inv(W_y+A'*W_z*A)*(xi_y+A'*xi_z)

# Forward to OUT
function sumProduct!{T<:MvGaussianDistribution}(node::GainAdditionNode,
                                                outbound_interface_index::Int,
                                                in1::Message{T},
                                                in2::Message{T},
                                                ::Void)
    (isProper(in1.payload) && isProper(in2.payload)) || error("Improper input distributions are not supported")
    if outbound_interface_index == 3
        dist_out = ensureMessage!(node.interfaces[outbound_interface_index], MvGaussianDistribution{size(node.A, 1)}).payload

        dist_1 = in1.payload
        dist_2 = in2.payload

        # Select parameterization
        # Order is from least to most computationally intensive
        if isValid(dist_1.m) && isValid(dist_1.V) && isValid(dist_2.m) && isValid(dist_2.V)
            dist_out.m  = forwardGainAdditionMRule(node.A, dist_2.m, dist_1.m)
            dist_out.V  = forwardGainAdditionVRule(node.A, dist_2.V, dist_1.V)
            invalidate!(dist_out.W)
            invalidate!(dist_out.xi)
        elseif isValid(dist_1.m) && isValid(dist_1.W) && isValid(dist_2.m) && isValid(dist_2.W)
            dist_out.m  = forwardGainAdditionMRule(node.A, dist_2.m, dist_1.m)
            invalidate!(dist_out.V)
            dist_out.W  = forwardGainAdditionWRule(node.A, dist_2.W, dist_1.W)
            invalidate!(dist_out.xi)
        elseif isValid(dist_1.xi) && isValid(dist_1.W) && isValid(dist_2.xi) && isValid(dist_2.W)
            invalidate!(dist_out.m)
            invalidate!(dist_out.V)
            dist_out.W  = forwardGainAdditionWRule(node.A, dist_2.W, dist_1.W)
            dist_out.xi = forwardGainAdditionXiRule(node.A, dist_2.xi, dist_1.xi, dist_2.W, dist_1.W)
        elseif (isValid(dist_1.m) && isValid(dist_1.V)) || (isValid(dist_2.m) && isValid(dist_2.V))
            # Fallback: at least one inbound msg is in (m,V) parametrization
            # Convert the other one to (m,V)
            ensureParameters!(dist_1, (:m, :V))
            ensureParameters!(dist_2, (:m, :V))
            dist_out.m  = forwardGainAdditionMRule(node.A, dist_2.m, dist_1.m)
            dist_out.V  = forwardGainAdditionVRule(node.A, dist_2.V, dist_1.V)
            invalidate!(dist_out.W)
            invalidate!(dist_out.xi)
        elseif (isValid(dist_1.m) && isValid(dist_1.W)) || (isValid(dist_2.m) && isValid(dist_2.W))
            # Fallback: at least one inbound msg is in (m,W) parametrization
            # Convert the other one to (m,W)
            ensureParameters!(dist_1, (:m, :W))
            ensureParameters!(dist_2, (:m, :W))
            dist_out.m  = forwardGainAdditionMRule(node.A, dist_2.m, dist_1.m)
            invalidate!(dist_out.V)
            dist_out.W  = forwardGainAdditionWRule(node.A, dist_2.W, dist_1.W)
            invalidate!(dist_out.xi)
        else
            # Fallback: if all else fails, convert everything to (m,V) and then use efficient rule
            ensureParameters!(dist_1, (:m, :V))
            ensureParameters!(dist_2, (:m, :V))
            dist_out.m  = forwardGainAdditionMRule(node.A, dist_2.m, dist_1.m)
            dist_out.V  = forwardGainAdditionVRule(node.A, dist_2.V, dist_1.V)
            invalidate!(dist_out.W)
            invalidate!(dist_out.xi)
        end

        return (:gain_addition_gaussian_forward,
                node.interfaces[outbound_interface_index].message)
    else
        error("Invalid outbound interface id $(outbound_interface_index), on $(typeof(node)) $(node.id).")
    end
end

# Backward to IN2
function sumProduct!{T<:MvGaussianDistribution}(node::GainAdditionNode,
                                                outbound_interface_index::Int,
                                                in1::Message{T},
                                                ::Void,
                                                out::Message{T})
    (isProper(in1.payload) && isProper(out.payload)) || error("Improper input distributions are not supported")
    if outbound_interface_index == 2
        dist_out = ensureMessage!(node.interfaces[outbound_interface_index], MvGaussianDistribution{size(node.A_inv, 1)}).payload

        dist_1 = in1.payload
        dist_3 = out.payload

        # Select parameterization
        # Order is from least to most computationally intensive
        if isValid(dist_1.m) && isValid(dist_1.V) && isValid(dist_3.m) && isValid(dist_3.V)
            dist_out.m  = backwardIn2GainAdditionMRule(node.A, dist_1.m, dist_3.m)
            dist_out.V  = backwardIn2GainAdditionVRule(node.A, dist_1.V, dist_3.V)
            invalidate!(dist_out.W)
            invalidate!(dist_out.xi)
        elseif isValid(dist_1.m) && isValid(dist_1.W) && isValid(dist_3.m) && isValid(dist_3.W)
            dist_out.m  = backwardIn2GainAdditionMRule(node.A, dist_1.m, dist_3.m)
            invalidate!(dist_out.V)
            dist_out.W  = backwardIn2GainAdditionWRule(node.A, dist_1.W, dist_3.W)
            invalidate!(dist_out.xi)
        elseif isValid(dist_1.xi) && isValid(dist_1.W) && isValid(dist_3.xi) && isValid(dist_3.W)
            invalidate!(dist_out.m)
            invalidate!(dist_out.V)
            dist_out.W  = backwardIn2GainAdditionWRule(node.A, dist_1.W, dist_3.W)
            dist_out.xi = backwardIn2GainAdditionXiRule(node.A, dist_1.xi, dist_3.xi, dist_1.W, dist_3.W)
        elseif (isValid(dist_1.m) && isValid(dist_1.V)) || (isValid(dist_3.m) && isValid(dist_3.V))
            # Fallback: at least one inbound msg is in (m,V) parametrization
            # Convert the other one to (m,V)
            ensureParameters!(dist_1, (:m, :V))
            ensureParameters!(dist_3, (:m, :V))
            dist_out.m  = backwardIn2GainAdditionMRule(node.A, dist_1.m, dist_3.m)
            dist_out.V  = backwardIn2GainAdditionVRule(node.A, dist_1.V, dist_3.V)
            invalidate!(dist_out.W)
            invalidate!(dist_out.xi)
        elseif (isValid(dist_1.m) && isValid(dist_1.W)) || (isValid(dist_3.m) && isValid(dist_3.W))
            # Fallback: at least one inbound msg is in (m,W) parametrization
            # Convert the other one to (m,W)
            ensureParameters!(dist_1, (:m, :W))
            ensureParameters!(dist_3, (:m, :W))
            dist_out.m  = backwardIn2GainAdditionMRule(node.A, dist_1.m, dist_3.m)
            invalidate!(dist_out.V)
            dist_out.W  = backwardIn2GainAdditionWRule(node.A, dist_1.W, dist_3.W)
            invalidate!(dist_out.xi)
        else
            # Fallback: if all else fails, convert everything to (m,V) and then use efficient rule
            ensureParameters!(dist_1, (:m, :V))
            ensureParameters!(dist_3, (:m, :V))
            dist_out.m  = backwardIn2GainAdditionMRule(node.A, dist_1.m, dist_3.m)
            dist_out.V  = backwardIn2GainAdditionVRule(node.A, dist_1.V, dist_3.V)
            invalidate!(dist_out.W)
            invalidate!(dist_out.xi)
        end

        return (:gain_addition_gaussian_backward_in2,
                node.interfaces[outbound_interface_index].message)
    else
        error("Invalid outbound interface id $(outbound_interface_index), on $(typeof(node)) $(node.id).")
    end
end

# Backward to IN1
function sumProduct!{T<:MvGaussianDistribution}(node::GainAdditionNode,
                                                outbound_interface_index::Int,
                                                ::Void,
                                                in2::Message{T},
                                                out::Message{T})
    (isProper(in2.payload) && isProper(out.payload)) || error("Improper input distributions are not supported")
    if outbound_interface_index == 1
        dist_temp = vague(MvGaussianDistribution{size(node.A, 1)})
        additionGaussianBackwardRule!(dist_temp, in2.payload, out.payload)
        dist_out = ensureMessage!(node.interfaces[outbound_interface_index], MvGaussianDistribution{size(node.A_inv, 1)}).payload
        fixedGainGaussianBackwardRule!(dist_out, dist_temp, node.A, (isdefined(node, :A_inv)) ? node.A_inv : nothing)

        return (:gain_addition_gaussian_backward_in1,
            node.interfaces[outbound_interface_index].message)
    else
        error("Invalid outbound interface id $(outbound_interface_index), on $(typeof(node)) $(node.id).")
    end
end
