# Aidan Holloway-Bidwell, Lucy Lu, Grant Terrien, Renzhi Wu
# Baum-Welch training
import numpy as np

# calculate forward probability matrix
def alpha(A, B, observations):

	T = len(observations)
	num_states, num_obs = B.shape

	fw = np.zeros((num_states, T))

	initial = [0.25, 0.20, 0.10, 0.45]
	for index, prob in enumerate(initial):
		fw[index, 0] = prob * B[index, observations[0]]	

	for t in range(1, T):
		for j in range(num_states):
			for i in range(num_states):
				fw[j,t] += fw[i,t-1] * A[i,j]
			fw[j,t] *= B[j,observations[t]]

	return fw

# calculate backward probability matrix
def beta(A, B, observations):

	T = len(observations)
	num_states, num_obs = B.shape

	bw = np.zeros((num_states, T))

	# Assuming if a state is last, it has a 1.0 prob of being last.
	# If this is not true, line below may have to be changed.
	bw[:,-1] = 1.0

	for t in range(T-2, -1, -1):
		for i in range(num_states):
			for j in range(num_states):
				bw[i,t] += bw[j,t+1] * A[i,j] * B[j,observations[t + 1]]

	return bw

# Calculate probability of going from state i to j, given probability sequence,
# at any time t
def xi(A, B, alpha, beta, observations):
	prob = prob_obs(alpha)

	num_states = A.shape[0]
	T = len(observations)
	xi = np.zeros((T, num_states, num_states))

	for i_ind in range(num_states):
		for j_ind in range(num_states):
			for t_ind in range(T - 1):
				not_quite_xi = \
					alpha[i_ind,t_ind] * \
					beta[j_ind,t_ind + 1] * \
					A[i_ind,j_ind] * \
					B[j_ind, observations[t_ind + 1]]

				xi[t_ind,i_ind,j_ind] = not_quite_xi / prob

	return xi

def prob_obs(alpha):
	return sum(alpha.T[-1])

def a_hat(xi):
	T, num_states = xi.shape[:2]
	a_hat = np.zeros((num_states, num_states))

	for i in range(num_states):
		for j in range(num_states):
			a_hat[i, j] = np.sum(xi[0:T, i, j]) / np.sum(xi[0:T, i, :])

	return a_hat

# Calculate the probability of being in state j at time t
def gamma(alpha, beta, observations):
	prob = prob_obs(alpha)

	T = len(observations)
	num_states = alpha.shape[0]
	gamma = np.zeros((T, num_states))

	for t_ind in range(T):
		for j_ind in range(num_states):
			gamma[t_ind, j_ind] = alpha[j_ind, t_ind] * beta[j_ind, t_ind] / prob

	return gamma

def b_hat(B, gamma, observations):
	num_states, num_obs = B.shape
	T = len(observations)

	b_hat = np.zeros((num_states, num_obs))

	for i_ind in range(num_states):
		for o_ind in range(num_obs):
			for t_ind in range(T):
				if observations[t_ind] == o_ind:
					b_hat[i_ind, o_ind] += gamma[t_ind, i_ind]
			b_hat[i_ind, o_ind] /= sum(gamma[:, i_ind])

	return b_hat


def baum_welch(A, B, observations):
	curA = A
	curB = B
	num_states, num_obs = B.shape
	T = len(observations)

	count = 1
	while True:
		alph = alpha(curA, curB, observations)
		bet = beta(curA, curB, observations)

		x = xi(curA, curB, alph, bet, observations)
		gam = gamma(alph, bet, observations)

		oldA, oldB = curA, curB

		curA = a_hat(x)
		curB = b_hat(oldB, gam, observations)


		if np.linalg.norm(oldA - curA) < .00001 and np.linalg.norm(oldB - curB) < .00001:
			break

		count += 1

	return curA, curB


# Deprecated by the tests.py module
def test():
	A = np.array([0.6794, 0.3206, 0.0, 0.0, \
				  0.0, 0.5366, 0.4634, 0.0, \
				  0.0, 0.0, 0.3485, 0.6516, \
				  0.1508, 0.0, 0.0, 0.8492])

	B = np.array([0.6884, 0.0015, 0.3002, 0.0099, \
				  0.0, 0.7205, 0.0102, 0.2694, \
				  0.2894, 0.3731, 0.3362, 0.0023, \
				  0.0005, 0.8440, 0.0021, 0.1534])

	A = A.reshape((-1,4))
	B = B.reshape((-1,4))

	#print(A, B)

	O = np.array([0,3,1,2,1,0,2,3,0,1,0,2,0,1,2,2,0,3,0,0,2,0,0,1,2,0,1,2,0])

	alph = alpha(A, B, O)
	bet = beta(A, B, O)

	print(alph.T)
	print(bet.T)

	T = len(O)
	num_states, num_obs = B.shape

	#print(xi(A, B, alph, bet, prob_obs, O))
	#print(baum_welch(A,B,O))









