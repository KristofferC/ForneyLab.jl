############################################
# AdditionNode
############################################
# Description:
#   Addition of two messages of same type.
#
#          in2
#          |
#    in1   v  out
#   ----->[+]----->
#
#   out = in1 + in2
#
#   Example:
#       AdditionNode(; name="my_node")
#
# Interface ids, (names) and supported message types:
#   1. (in1):
#       Message{GaussianDistribution}
#       Message{DeltaDistribution}
#   2. (in2):
#       Message{GaussianDistribution}
#       Message{DeltaDistribution}
#   3. (out):
#       Message{GaussianDistribution}
#       Message{DeltaDistribution}
############################################

export AdditionNode

type AdditionNode <: Node
    name::ASCIIString
    interfaces::Array{Interface,1}
    in1::Interface
    in2::Interface
    out::Interface

    function AdditionNode(; name=unnamedStr())
        self = new(name, Array(Interface, 3))

        named_handle_list = [:in1, :in2, :out]
        for i = 1:length(named_handle_list)
            self.interfaces[i] = Interface(self)
            setfield!(self, named_handle_list[i], self.interfaces[i])
        end

        return self
    end
end

isDeterministic(::AdditionNode) = true

############################################
# GaussianDistribution methods
############################################

# Rule set for forward propagation, from: Korl (2005), "A Factor graph approach to signal modelling, system identification and filtering", Table 4.1
forwardAdditionMRule{T<:Number}(m_x::Array{T, 1}, m_y::Array{T, 1}) = m_x + m_y
forwardAdditionVRule{T<:Number}(V_x::Array{T, 2}, V_y::Array{T, 2}) = V_x + V_y
forwardAdditionWRule{T<:Number}(W_x::Array{T, 2}, W_y::Array{T, 2}) = W_x * pinv(W_x + W_y) * W_y
forwardAdditionXiRule{T<:Number}(V_x::Array{T, 2}, xi_x::Array{T, 1}, V_y::Array{T, 2}, xi_y::Array{T, 1}) = pinv(V_x + V_y) * (V_x*xi_x + V_y*xi_y)

# Rule set for backward propagation, from: Korl (2005), "A Factor graph approach to signal modelling, system identification and filtering", Table 4.1
# The backward propagation merely negates the mean of the present input message (edge X) and uses the same rules to determine the missing input (edge Y)
# For the sake of clarity there is some redundancy between forward and backward rules.
backwardAdditionMRule{T<:Number}(m_x::Array{T, 1}, m_z::Array{T, 1}) = m_z - m_x
backwardAdditionVRule{T<:Number}(V_x::Array{T, 2}, V_z::Array{T, 2}) = V_x + V_z
backwardAdditionWRule{T<:Number}(W_x::Array{T, 2}, W_z::Array{T, 2}) = W_x * pinv(W_x + W_z) * W_z
backwardAdditionXiRule{T<:Number}(V_x::Array{T, 2}, xi_x::Array{T, 1}, V_z::Array{T, 2}, xi_z::Array{T, 1}) = pinv(V_x + V_z) * (V_z*xi_z - V_x*xi_x)

# Message towards OUT
function sumProduct!(node::AdditionNode,
                            outbound_interface_id::Int,
                            msg_in1::Message{GaussianDistribution},
                            msg_in2::Message{GaussianDistribution},
                            msg_out::Nothing)
    dist_out = ensureMessage!(node.out, GaussianDistribution).payload
    dist_1 = msg_in1.payload
    dist_2 = msg_in2.payload

    # Select parameterization
    # Order is from least to most computationally intensive
    if isValid(dist_1.m) && isValid(dist_1.V) && isValid(dist_2.m) && isValid(dist_2.V)
        dist_out.m = forwardAdditionMRule(dist_1.m, dist_2.m)
        dist_out.V = forwardAdditionVRule(dist_1.V, dist_2.V)
        invalidate!(dist_out.W) 
        invalidate!(dist_out.xi)
    elseif isValid(dist_1.m) && isValid(dist_1.W) && isValid(dist_2.m) && isValid(dist_2.W)
        dist_out.m = forwardAdditionMRule(dist_1.m, dist_2.m)
        invalidate!(dist_out.V) 
        dist_out.W = forwardAdditionWRule(dist_1.W, dist_2.W)
        invalidate!(dist_out.xi)
    elseif isValid(dist_1.xi) && isValid(dist_1.V) && isValid(dist_2.xi) && isValid(dist_2.V)
        invalidate!(dist_out.m) 
        dist_out.V = forwardAdditionVRule(dist_1.V, dist_2.V)
        invalidate!(dist_out.W) 
        dist_out.xi= forwardAdditionXiRule(dist_1.V, dist_1.xi, dist_2.V, dist_2.xi)
    else
        # Last resort: calculate (m,V) parametrization for both inbound messages
        ensureMVParametrization!(dist_1)
        ensureMVParametrization!(dist_2)
        dist_out.m = forwardAdditionMRule(dist_1.m, dist_2.m)
        dist_out.V = forwardAdditionVRule(dist_1.V, dist_2.V)
        invalidate!(dist_out.W) 
        invalidate!(dist_out.xi)
    end

    return (:addition_gaussian_forward,
            node.interfaces[outbound_interface_id].message)
end

# Message towards IN1 or IN2
function sumProduct!(node::AdditionNode,
                            outbound_interface_id::Int,
                            msg_in1::Message{GaussianDistribution},
                            ::Nothing,
                            msg_out::Message{GaussianDistribution})
    dist_out = ensureMessage!(node.interfaces[outbound_interface_id], GaussianDistribution).payload

    # Calculations for the GaussianDistribution type; Korl (2005), table 4.1
    # Backward message, one message on the incoming edge and one on the outgoing edge.
    dist_1 = msg_in1.payload
    dist_3 = msg_out.payload

    # Select parameterization
    # Order is from least to most computationally intensive
    if isValid(dist_1.m) && isValid(dist_1.V) && isValid(dist_3.m) && isValid(dist_3.V)
        dist_out.m = backwardAdditionMRule(dist_1.m, dist_3.m)
        dist_out.V = backwardAdditionVRule(dist_1.V, dist_3.V)
        invalidate!(dist_out.W) 
        invalidate!(dist_out.xi) 
    elseif isValid(dist_1.m) && isValid(dist_1.W) && isValid(dist_3.m) && isValid(dist_3.W)
        dist_out.m = backwardAdditionMRule(dist_1.m, dist_3.m)
        invalidate!(dist_out.V) 
        dist_out.W = backwardAdditionWRule(dist_1.W, dist_3.W)
        invalidate!(dist_out.xi) 
    elseif isValid(dist_1.xi) && isValid(dist_1.V) && isValid(dist_3.xi) && isValid(dist_3.V)
        invalidate!(dist_out.m) 
        dist_out.V = backwardAdditionVRule(dist_1.V, dist_3.V)
        invalidate!(dist_out.W) 
        dist_out.xi = backwardAdditionXiRule(dist_1.V, dist_1.xi, dist_3.V, dist_3.xi)
    else
        # Last resort: calculate (m,V) parametrization for both inbound messages
        ensureMVParametrization!(dist_1)
        ensureMVParametrization!(dist_3)
        dist_out.m = backwardAdditionMRule(dist_1.m, dist_3.m)
        dist_out.V = backwardAdditionVRule(dist_1.V, dist_3.V)
        invalidate!(dist_out.W) 
        invalidate!(dist_out.xi) 
    end

    return (:addition_gaussian_backward,
            node.interfaces[outbound_interface_id].message)
end
sumProduct!(node::AdditionNode, outbound_interface_id::Int, ::Nothing, msg_in2::Message{GaussianDistribution}, msg_out::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_id, msg_in2, nothing, msg_out)


#############################################
# DeltaDistribution methods
#############################################

# Message towards OUT
function sumProduct!{T<:Any}(
                            node::AdditionNode,
                            outbound_interface_id::Int,
                            msg_in1::Message{DeltaDistribution{T}},
                            msg_in2::Message{DeltaDistribution{T}},
                            msg_out::Nothing)
    ans = msg_in1.payload.m + msg_in2.payload.m
    msg_result = ensureMessage!(node.out, DeltaDistribution{T})
    msg_result.payload.m = ans

    return (:addition_delta_forward,
            node.interfaces[outbound_interface_id].message)
end

# Message towards IN1 or IN2
function sumProduct!{T<:Any}(node::AdditionNode,
                            outbound_interface_id::Int,
                            msg_in1::Message{DeltaDistribution{T}},
                            ::Nothing,
                            msg_out::Message{DeltaDistribution{T}})
    ans = msg_out.payload.m - msg_in1.payload.m

    msg_result = ensureMessage!(node.interfaces[outbound_interface_id], DeltaDistribution{T})
    msg_result.payload.m = ans

    return (:addition_delta_backward,
            node.interfaces[outbound_interface_id].message)
end
sumProduct!{T<:Any}(node::AdditionNode, outbound_interface_id::Int, ::Nothing, msg_in2::Message{DeltaDistribution{T}}, msg_out::Message{DeltaDistribution{T}}) = sumProduct!(node, outbound_interface_id, msg_in2, nothing, msg_out)


############################################
# Gaussian-DeltaDistribution combination
############################################

# Forward
sumProduct!{T<:Any}(node::AdditionNode, outbound_interface_id::Int, msg_in1::Message{DeltaDistribution{T}}, msg_in2::Message{GaussianDistribution}, ::Nothing) = sumProduct!(node, outbound_interface_id, convert(Message{GaussianDistribution}, msg_in1), msg_in2, nothing)
sumProduct!{T<:Any}(node::AdditionNode, outbound_interface_id::Int, msg_in1::Message{GaussianDistribution}, msg_in2::Message{DeltaDistribution{T}}, ::Nothing) = sumProduct!(node, outbound_interface_id, msg_in1, convert(Message{GaussianDistribution}, msg_in2), nothing)
# Backward to in1
sumProduct!{T<:Any}(node::AdditionNode, outbound_interface_id::Int, ::Nothing, msg_in2::Message{DeltaDistribution{T}}, msg_out::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_id, nothing, convert(Message{GaussianDistribution}, msg_in2), msg_out)
sumProduct!{T<:Any}(node::AdditionNode, outbound_interface_id::Int, ::Nothing, msg_in2::Message{GaussianDistribution}, msg_out::Message{DeltaDistribution{T}}) = sumProduct!(node, outbound_interface_id, nothing, msg_in2, convert(Message{GaussianDistribution}, msg_out))
# Backward to in2
sumProduct!{T<:Any}(node::AdditionNode, outbound_interface_id::Int, msg_in1::Message{DeltaDistribution{T}}, ::Nothing, msg_out::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_id, convert(Message{GaussianDistribution}, msg_in1), nothing, msg_out)
sumProduct!{T<:Any}(node::AdditionNode, outbound_interface_id::Int, msg_in1::Message{GaussianDistribution}, ::Nothing, msg_out::Message{DeltaDistribution{T}}) = sumProduct!(node, outbound_interface_id, msg_in1, nothing, convert(Message{GaussianDistribution}, msg_out))
