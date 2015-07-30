############################################
# EqualityNode
############################################
# Description:
#   Equality constraint on 3 variables: i[1] = i[2] = i[3]
#
#          i[2]
#          |
#    i[1]  |  i[3]
#   ------[=]-----
#
#   f(i1,i2,i3) = δ(i1-i3)⋅δ(i2-i3)
#
# Interfaces:
#   1 i[1], 2 i[2], 3 i[3]
#
# Construction:
#   EqualityNode(id=:my_node)
#
############################################

export EqualityNode

type EqualityNode <: Node
    id::Symbol
    interfaces::Array{Interface,1}
    i::Dict{Int,Interface}

    function EqualityNode(; id=generateNodeId(EqualityNode))
        self = new(id, Array(Interface, 3), Dict{Int,Interface}())
        addNode!(current_graph, self)
 
        for interface_index = 1:3
            self.i[interface_index] = self.interfaces[interface_index] = Interface(self)
        end

        return self
    end
end

isDeterministic(::EqualityNode) = true

# Implement firstFreeInterface since EqualityNode is symmetrical in its interfaces
function firstFreeInterface(node::EqualityNode)
    # Return the first free interface of a symmetrical node
    for interface in node.interfaces
        if interface.partner == nothing
            return interface
        end
    end
    error("No free interface on $(typeof(node)) $(node.id)")
end

############################################
# GaussianDistribution methods
############################################

# Rule set
# From: Korl (2005), "A Factor graph approach to signal modelling, system identification and filtering", Table 4.1
equalityMRule{T<:Number}(m_x::Array{T, 1}, m_y::Array{T, 1}, W_x::Array{T, 2}, W_y::Array{T, 2}) = pinv(W_x+W_y)*(W_x*m_x+W_y*m_y)
equalityVRule{T<:Number}(V_x::Array{T, 2}, V_y::Array{T, 2}) = V_x*pinv(V_x+V_y)*V_y
equalityWRule{T<:Number}(W_x::Array{T, 2}, W_y::Array{T, 2}) = W_x+W_y
equalityXiRule{T<:Number}(xi_x::Array{T, 1}, xi_y::Array{T, 1}) = xi_x+xi_y

function equalityGaussianRule!(dist_result::GaussianDistribution, dist_1::GaussianDistribution, dist_2::GaussianDistribution)
    # The result of the Gaussian equality rule applied to dist_1 and dist_2 is written to dist_result
    # The following update rules correspond to node 1 from Table 4.1 in:
    # Korl, Sascha. “A Factor Graph Approach to Signal Modelling, System Identification and Filtering.” Hartung-Gorre, 2005.
    if isValid(dist_1.m) && isValid(dist_1.W) && isValid(dist_2.m) && isValid(dist_2.W)
        dist_result.m  = equalityMRule(dist_1.m, dist_2.m, dist_1.W, dist_2.W)
        invalidate!(dist_result.V) 
        dist_result.W  = equalityWRule(dist_1.W, dist_2.W)
        invalidate!(dist_result.xi)
    elseif isValid(dist_1.xi) && isValid(dist_1.V) && isValid(dist_2.xi) && isValid(dist_2.V)
        invalidate!(dist_result.m) 
        dist_result.V  = equalityVRule(dist_1.V, dist_2.V)
        invalidate!(dist_result.W) 
        dist_result.xi = equalityXiRule(dist_1.xi, dist_2.xi)
    else
        # Use (xi,W)
        ensureXiWParametrization!(dist_1)
        ensureXiWParametrization!(dist_2)
        invalidate!(dist_result.m) 
        invalidate!(dist_result.V) 
        dist_result.W  = equalityWRule(dist_1.W, dist_2.W)
        dist_result.xi = equalityXiRule(dist_1.xi, dist_2.xi)
    end

    return dist_result
end

function sumProduct!(node::EqualityNode,
                            outbound_interface_index::Int,
                            msg_1::Message{GaussianDistribution},
                            msg_2::Message{GaussianDistribution},
                            ::Nothing)
    # Calculate an outbound message based on the inbound messages and the node function.
    dist_result = ensureMessage!(node.interfaces[outbound_interface_index], GaussianDistribution).payload

    equalityGaussianRule!(dist_result, msg_1.payload, msg_2.payload)

    return (:equality_gaussian,
            node.interfaces[outbound_interface_index].message)
end
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_1::Message{GaussianDistribution}, msg_2::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_1::Message{GaussianDistribution}, ::Nothing, msg_2::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)

############################################
# Gaussian-Student's t combination
############################################

function equalityGaussianStudentsTRule!(dist_result::GaussianDistribution, dist_1::GaussianDistribution, dist_2::StudentsTDistribution)
    # The result of the Gaussian-Student's t equality rule applied to dist_1 and dist_2 is written to dist_result
    # The student's t distribution is approximated by a Gaussian by moment matching.
    # The result is a Gaussian approximation to the exact result.

    ensureMWParametrization!(dist_1)
    approx_m = mean(dist_2)
    approx_W = inv(var(dist_2))
    dist_result.m  = equalityMRule(dist_1.m, approx_m, dist_1.W, approx_W)
    dist_result.W  = equalityWRule(dist_1.W, approx_W)
    invalidate!(dist_result.V)
    invalidate!(dist_result.xi)

    return dist_result
end
equalityGaussianStudentsTRule!(dist_result::GaussianDistribution, dist_1::StudentsTDistribution, dist_2::GaussianDistribution) = equalityGaussianStudentsTRule!(dist_result, dist_2, dist_1)

function sumProduct!(node::EqualityNode,
                            outbound_interface_index::Int,
                            msg_st::Message{StudentsTDistribution},
                            msg_n::Message{GaussianDistribution},
                            ::Nothing)
    # Combination of Gaussian and student's t-distribution
    # Definitions available in derivations notebook
    # Same as Gaussian equality rule

    dist_result = ensureMessage!(node.interfaces[outbound_interface_index], GaussianDistribution).payload

    equalityGaussianStudentsTRule!(dist_result, msg_st.payload, msg_n.payload)

    return (:equality_gaussian_student,
            node.interfaces[outbound_interface_index].message)
end
# Call signature for messages other ways around
# Outbound interface 3
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_n::Message{GaussianDistribution}, msg_st::Message{StudentsTDistribution}, ::Nothing) = sumProduct!(node, outbound_interface_index, msg_st, msg_n, nothing)
# Outbound interface 2
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_n::Message{GaussianDistribution}, ::Nothing, msg_st::Message{StudentsTDistribution}) = sumProduct!(node, outbound_interface_index, msg_st, msg_n, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_st::Message{StudentsTDistribution}, ::Nothing, msg_n::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_index, msg_st, msg_n, nothing)
# Outbound interface 1
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_n::Message{GaussianDistribution}, msg_st::Message{StudentsTDistribution}) = sumProduct!(node, outbound_interface_index, msg_st, msg_n, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_st::Message{StudentsTDistribution}, msg_n::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_index, msg_st, msg_n, nothing)

############################################
# DeltaDistribution methods
############################################

function equalityDeltaRule!(dist_result::DeltaDistribution, dist_1::DeltaDistribution, dist_2::DeltaDistribution)
    # The result of the delta equality rule applied to dist_1 and dist_2 is written to dist_result
    # Outbound message is equal to the inbound messages if both inbound messages are equal.
    # Otherwise, the outbound message is 0.0
    if dist_1 == dist_2
        dist_result.m = copy(dist_1.m)
    else
        dist_result.m = zero(dist_1.m)
    end

    return dist_result
end

function sumProduct!(node::EqualityNode,
                     outbound_interface_index::Int,
                     msg_1::Message{DeltaDistribution{Float64}},
                     msg_2::Message{DeltaDistribution{Float64}},
                     ::Nothing)
    # Calculate an outbound message based on the inbound messages and the node function.

    dist_result = ensureMessage!(node.interfaces[outbound_interface_index], DeltaDistribution{Float64}).payload

    equalityDeltaRule!(dist_result, msg_1.payload, msg_2.payload)

    return (:equality_delta,
            node.interfaces[outbound_interface_index].message)
end
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_1::Message{DeltaDistribution{Float64}}, ::Nothing, msg_2::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_1::Message{DeltaDistribution{Float64}}, msg_2::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)


############################################
# InverseGammaDistribution methods
############################################

function equalityInverseGammaRule!(dist_result::InverseGammaDistribution, dist_1::InverseGammaDistribution, dist_2::InverseGammaDistribution)
    # The result of the inverse gamma equality rule applied to dist_1 and dist_2 is written to dist_result
    # Definition from Korl table 5.2
    dist_result.a = dist_1.a+dist_2.a+1.0
    dist_result.b = dist_1.b+dist_2.b
    return dist_result
end 

function sumProduct!(node::EqualityNode,
                            outbound_interface_index::Int,
                            msg_1::Message{InverseGammaDistribution},
                            msg_2::Message{InverseGammaDistribution},
                            ::Nothing)
    # Calculate an outbound message based on the inbound messages and the node function.
    # This function is not exported, and is only meant for internal use.
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], InverseGammaDistribution).payload

    equalityInverseGammaRule!(dist_out, msg_1.payload, msg_2.payload)

    return (:equality_inverse_gamma,
            node.interfaces[outbound_interface_index].message)
end
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_1::Message{InverseGammaDistribution}, ::Nothing, msg_2::Message{InverseGammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_1::Message{InverseGammaDistribution}, msg_2::Message{InverseGammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)

############################################
# GammaDistribution methods
############################################

function equalityGammaRule!(dist_result::GammaDistribution, dist_1::GammaDistribution, dist_2::GammaDistribution)
    # The result of the gamma equality rule applied to dist_1 and dist_2 is written to dist_result
    # Derivation available in notebook
    dist_result.a = dist_1.a+dist_2.a-1.0
    dist_result.b = dist_1.b+dist_2.b
    return dist_result
end    

function sumProduct!(node::EqualityNode,
                            outbound_interface_index::Int,
                            msg_1::Message{GammaDistribution},
                            msg_2::Message{GammaDistribution},
                            ::Nothing)
    # Calculate an outbound message based on the inbound messages and the node function.
    # This function is not exported, and is only meant for internal use.
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], GammaDistribution).payload

    equalityGammaRule!(dist_out, msg_1.payload, msg_2.payload)

    return (:equality_gamma,
            node.interfaces[outbound_interface_index].message)
end
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_1::Message{GammaDistribution}, ::Nothing, msg_2::Message{GammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_1::Message{GammaDistribution}, msg_2::Message{GammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)

############################################
# BetaDistribution methods
############################################

function equalityBetaRule!(dist_result::BetaDistribution, dist_1::BetaDistribution, dist_2::BetaDistribution)
    # The result of the beta equality rule applied to dist_1 and dist_2 is written to dist_result
    # Derivation available in notebook
    dist_result.a = dist_1.a+dist_2.a-1.0
    dist_result.b = dist_1.b+dist_2.b-1.0
    return dist_result
end    

function sumProduct!(node::EqualityNode,
                            outbound_interface_index::Int,
                            msg_1::Message{BetaDistribution},
                            msg_2::Message{BetaDistribution},
                            ::Nothing)
    # Calculate an outbound message based on the inbound messages and the node function.
    # This function is not exported, and is only meant for internal use.
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], BetaDistribution).payload

    equalityBetaRule!(dist_out, msg_1.payload, msg_2.payload)

    return (:equality_beta,
            node.interfaces[outbound_interface_index].message)
end
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_1::Message{BetaDistribution}, ::Nothing, msg_2::Message{BetaDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_1::Message{BetaDistribution}, msg_2::Message{BetaDistribution}) = sumProduct!(node, outbound_interface_index, msg_1, msg_2, nothing)

############################################
# Gaussian-DeltaDistribution combination
############################################

function equalityGaussianDeltaRule!(dist_result::DeltaDistribution{Float64}, dist_1::GaussianDistribution, dist_2::DeltaDistribution{Float64})
    dist_result.m = deepcopy(dist_2.m)
    return dist_result
end
equalityGaussianDeltaRule!(dist_result::DeltaDistribution{Float64}, dist_1::DeltaDistribution{Float64}, dist_2::GaussianDistribution) = equalityGaussianDeltaRule!(dist_result, dist_2, dist_1)

function equalityGaussianDeltaRule!(dist_result::GaussianDistribution, dist_1::GaussianDistribution, dist_2::DeltaDistribution{Float64})
    dist_result.m = deepcopy(dist_2.m)
    dist_result.V = eye(length(dist_2.m))*tiny()
    invalidate!(dist_result.W) 
    invalidate!(dist_result.xi) 
    return dist_result
end
equalityGaussianDeltaRule!(dist_result::GaussianDistribution, dist_1::DeltaDistribution{Float64}, dist_2::GaussianDistribution) = equalityGaussianDeltaRule!(dist_result, dist_2, dist_1)

function sumProduct!(node::EqualityNode,
                     outbound_interface_index::Int,
                     msg_delta::Message{DeltaDistribution{Float64}},
                     msg_n::Message{GaussianDistribution},
                     ::Nothing)
    # Combination of Gaussian and delta
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], DeltaDistribution{Float64}).payload

    equalityGaussianDeltaRule!(dist_out, msg_delta.payload, msg_n.payload)

    return (:equality_gaussian_delta,
            node.interfaces[outbound_interface_index].message)
end
# Call signature for messages other ways around
# Outbound interface 3
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_n::Message{GaussianDistribution}, msg_delta::Message{DeltaDistribution{Float64}}, ::Nothing) = sumProduct!(node, outbound_interface_index, msg_delta, msg_n, nothing)
# Outbound interface 2
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_n::Message{GaussianDistribution}, ::Nothing, msg_delta::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_n, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_delta::Message{DeltaDistribution{Float64}}, ::Nothing, msg_n::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_n, nothing)
# Outbound interface 1
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_n::Message{GaussianDistribution}, msg_delta::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_n, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_delta::Message{DeltaDistribution{Float64}}, msg_n::Message{GaussianDistribution}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_n, nothing)

############################################
# Gamma-DeltaDistribution combination
############################################

function equalityGammaDeltaRule!(dist_result::DeltaDistribution{Float64}, dist_1::GammaDistribution, dist_2::DeltaDistribution{Float64})
    length(dist_2.m) == 1 || error("Equality gamma-delta update only implemented for univariate distributions")
    (dist_2.m[1] >= 0) || error("Can not perform equality rule for gamma-delta combination for negative numbers")
    dist_result.m = deepcopy(dist_2.m)
    return dist_result
end
equalityGammaDeltaRule!(dist_result::DeltaDistribution{Float64}, dist_1::DeltaDistribution{Float64}, dist_2::GammaDistribution) = equalityGammaDeltaRule!(dist_result, dist_2, dist_1)

function sumProduct!(node::EqualityNode,
                     outbound_interface_index::Int,
                     msg_delta::Message{DeltaDistribution{Float64}},
                     msg_gam::Message{GammaDistribution},
                     ::Nothing)
    # Combination of gamma and float
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], DeltaDistribution{Float64}).payload

    equalityGammaDeltaRule!(dist_out, msg_delta.payload, msg_gam.payload)

    return (:equality_gamma_delta,
            node.interfaces[outbound_interface_index].message)
end
# Call signature for messages other ways around
# Outbound interface 3
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_gam::Message{GammaDistribution}, msg_delta::Message{DeltaDistribution{Float64}}, ::Nothing) = sumProduct!(node, outbound_interface_index, msg_delta, msg_gam, nothing)
# Outbound interface 2
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_gam::Message{GammaDistribution}, ::Nothing, msg_delta::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_gam, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_delta::Message{DeltaDistribution{Float64}}, ::Nothing, msg_gam::Message{GammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_gam, nothing)
# Outbound interface 1
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_gam::Message{GammaDistribution}, msg_delta::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_gam, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_delta::Message{DeltaDistribution{Float64}}, msg_gam::Message{GammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_gam, nothing)

############################################
# InverseGamma-DeltaDistribution combination
############################################

function equalityInverseGammaDeltaRule!(dist_result::DeltaDistribution{Float64}, dist_1::InverseGammaDistribution, dist_2::DeltaDistribution{Float64})
    length(dist_2.m) == 1 || error("Equality inversegamma-delta update only implemented for univariate distributions")
    (dist_2.m[1] >= 0) || error("Can not perform equality rule for inverse gamma-delta combination for negative numbers")
    dist_result.m = deepcopy(dist_2.m)
    return dist_result
end
equalityInverseGammaDeltaRule!(dist_result::DeltaDistribution{Float64}, dist_1::DeltaDistribution{Float64}, dist_2::InverseGammaDistribution) = equalityInverseGammaDeltaRule!(dist_result, dist_2, dist_1)

function sumProduct!(node::EqualityNode,
                     outbound_interface_index::Int,
                     msg_delta::Message{DeltaDistribution{Float64}},
                     msg_igam::Message{InverseGammaDistribution},
                     ::Nothing)
    # Combination of gamma and float
    dist_out = ensureMessage!(node.interfaces[outbound_interface_index], DeltaDistribution{Float64}).payload

    equalityInverseGammaDeltaRule!(dist_out, msg_delta.payload, msg_igam.payload)

    return (:equality_inverse_gamma_delta,
            node.interfaces[outbound_interface_index].message)
end
# Call signature for messages other ways around
# Outbound interface 3
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_igam::Message{InverseGammaDistribution}, msg_delta::Message{DeltaDistribution{Float64}}, ::Nothing) = sumProduct!(node, outbound_interface_index, msg_delta, msg_igam, nothing)
# Outbound interface 2
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_igam::Message{InverseGammaDistribution}, ::Nothing, msg_delta::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_igam, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, msg_delta::Message{DeltaDistribution{Float64}}, ::Nothing, msg_igam::Message{InverseGammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_igam, nothing)
# Outbound interface 1
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_igam::Message{InverseGammaDistribution}, msg_delta::Message{DeltaDistribution{Float64}}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_igam, nothing)
sumProduct!(node::EqualityNode, outbound_interface_index::Int, ::Nothing, msg_delta::Message{DeltaDistribution{Float64}}, msg_igam::Message{InverseGammaDistribution}) = sumProduct!(node, outbound_interface_index, msg_delta, msg_igam, nothing)
