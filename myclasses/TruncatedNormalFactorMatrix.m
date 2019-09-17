classdef TruncatedNormalFactorMatrix < FactorMatrixInterface
    % TruncatedNormalFactorMatrix
    %   Detailed explanation goes here
    
    properties (Constant)
        supported_inference_methods = {'variational','sampling'}
        inference_default = 'variational';
    end
    
    % Attributes that are only relevant to this class and subclasses
    properties (Access = protected)
        opt_options = struct('hals_updates',10,...
            'permute', true);
        lowerbound = 0;
        upperbound = inf;
    
        %factor         % tnorm first moment
        factor_var;     % tnorm second moment
        
        factor_mu;      % mu parameter in tnorm
        factor_sig2;    % variance parameter in tnorm
        
        optimization_method;
    end
    
    properties (Access = protected)
        logZhatOUT;
    end
    
    %% Required functions
    methods
        % Constructor
        function obj = TruncatedNormalFactorMatrix(...
                shape, prior_choice, has_missing,...
                inference_method)
            
            obj.hyperparameter = prior_choice;
            obj.distribution = sprintf(['Element-wise Truncated (%2.1f, %2.1f) '...
                'Normal distribution'], obj.lowerbound, obj.upperbound);
            obj.factorsize = shape;
            obj.optimization_method = 'hals';
            obj.data_has_missing = has_missing;
            
            if shape(2) == 1
                % If there is only 1 component, then there is no use in
                % multiple HALS updates.
                obj.opt_options.hals_updates = 1;
            end
            
            if exist('inference_method','var')
                obj.inference_method = inference_method;
            else
                obj.inference_method = obj.inference_default;
            end
            
            
        end
        
        function updateFactor(self, update_mode, Xm, Rm, eFact, eFact2, eFact2elem, eNoise)
            
            if strcmpi(self.optimization_method,'hals')
                self.hals_update(update_mode, Xm, Rm, eFact, eFact2, eFact2elem, eNoise)
            else
                error('Unknown optimization method')
            end
            
        end
        
        function updateFactorPrior(self, eFact2, distr_const)
            if nargin < 3
                distr_const = [];
            end
            self.hyperparameter.updatePrior(eFact2, distr_const);
        end
        
        function eFact = getExpFirstMoment(self, eNoise)
            if nargin == 1
                eFact = self.factor;
            elseif nargin == 2
                eFact = bsxfun(@times, self.factor, eNoise);
            end
        end
        
        function eFact2 = getExpSecondMoment(self, eNoise)
            if nargin == 1
                eFact2 = self.factor'*self.factor+diag(sum(self.factor_var,1));
            elseif nargin == 2
                eFact2 = bsxfun(@times,self.factor,sqrt(eNoise))'*bsxfun(@times,self.factor,sqrt(eNoise))...
                    +diag(sum(self.factor_var.*eNoise,1));
            end
            
        end
        
        function eFact2elem = getExpSecondMomentElem(self, eNoise)
            if nargin == 1
                eFact2elem = self.factor.^2+self.factor_var;

            elseif nargin == 2
                eFact2elem = bsxfun(@times, self.factor.^2+self.factor_var, eNoise);
            end
        end
        
        function eFact2elempair = getExpElementwiseSecondMoment(self)
            [mu, covar] = computeUnfoldedMoments(self.factor,self.factor_var);
            eFact2elempair = mu+covar;
        end
        
        function cost = calcCost(self)
            if strcmpi(self.inference_method,'variational')
                cost = self.getLogPrior()+sum(sum(self.getEntropy()));
            elseif strcmpi(self.inference_method,'sampling')
                cost = self.getLogPrior();
            end
            
        end
        
        function entro = getEntropy(self)
            %Entropy calculation
            sig = sqrt(self.factor_sig2);
            alpha=(self.lowerbound-self.factor_mu)./sig;
            beta=(self.upperbound-self.factor_mu)./sig;
            
            if self.upperbound==inf
                if isa(alpha,'gpuArray')
                    r=exp(log(abs(alpha))+self.log_psi_func(alpha)-self.logZhatOUT); %GPU ready
                else
                    r=real(exp(log(alpha)+self.log_psi_func(alpha)-self.logZhatOUT));
                end
            else
                if isa(alpha,'gpuArray')
                    r=exp(log(abs(alpha))+self.log_psi_func(alpha)-self.logZhatOUT)...
                        -exp(log(abs(beta))+self.log_psi_func(beta)-self.logZhatOUT); %GPU ready
                else
                    r=real(exp(log(alpha)+self.log_psi_func(alpha)-self.logZhatOUT)...
                        -exp(log(beta)+self.log_psi_func(beta)-self.logZhatOUT));
                end
            end
            entro = log(sqrt(2*pi*exp(1)))+log(sig)+self.logZhatOUT+0.5*r;
            
            assert(~any(isnan(entro(:))),'Entropy was NaN')
            assert(~any(isinf(entro(:))),'Entropy was Inf')
        end
        
        function logp = getLogPrior(self)
            % Gets the prior contribution to the cost function.
            % Note. The hyperparameter needs to be updated before calculating
            % this.
            logp = numel(self.factor)*(-log(1/2)-1/2*log(2*pi))...
                +1/2*sum(self.hyperparameter.prior_log_value(:))...
                *numel(self.factor)/prod(self.hyperparameter.prior_size)...
                -1/2*sum(sum(bsxfun(@times, self.hyperparameter.getExpFirstMoment() , self.getExpSecondMomentElem())));
            %TODO: Can we use self.getExpSecondMoment() instead?
            
            if strcmpi(self.inference_method,'sampling')
                logp = numel(self.factor)*log(1/2)...
                    -sum(self.logZhatOUT(:));
                warning('Check if log prior is calculated correctly when sampling.')
            end
        end
        
        function samples = getSamples(self, num_samples)
            if nargin < 2
                num_samples = 1;
            end
            
            lb = self.lowerbound;
            ub = self.upperbound;
            
            samples = zeros([self.factorsize, num_samples]);
            for d = 1:self.factorsize(2)
                for i = 1:num_samples
                    mu = self.factor(:,d);
                    sig = sqrt(self.factor_sig2(:,d));

                    samples(:,d,i) = trandn( (lb-mu)./sig, (ub-mu)./sig ).*sig+mu;
                end
            end
            
        end
        
%         function ci = getCredibilityInterval(self, req_quantiles)
%               %% TODO: Can we calculate this theoretically?
%         end
        
    end
    
    %% Class specific functions
    methods (Access = protected)
        
        % Inferes the factor matrix by conditional updates, e.g. comparable
        % to the hierarchical alternating least squares (hals) framework,
        % using either Variational inference or Gibbs sampling.
        function hals_update(self, update_mode, Xm, Rm, eFact, eFact2,...
                eFact2pairwise, eNoise)
            
            ind=1:length(eFact);
            ind(update_mode) = [];
            
            % Calculate sufficient statistics
            kr = eFact{ind(1)};
            D = size(eFact{1},2);
            for i = ind(2:end)
                kr = krprod(eFact{i},kr);
            end
            
            
            Xmkr = Xm*kr;
            if self.data_has_missing
                if size(eFact2pairwise{1},2) == D
                    d_idx = 1:D;
                else
                    d_idx = D*( (1:D)-1)+(1:D);
                end

                if iscell(eNoise)
                    kr2_ = bsxfun(@times,...
                        eFact2pairwise{ind(1)}(:,d_idx),...
                        eNoise{ind(1)});
                else
                    kr2_ = eFact2pairwise{ind(1)}(:,d_idx);
                end

                for i = ind(2:end)

                    if iscell(eNoise)
                        kr2_ = krprod(bsxfun(@times,...
                            eFact2pairwise{i}(:,d_idx),...
                            eNoise{i}),...
                            kr2_);
                    else
                        kr2_ = krprod(eFact2pairwise{i}(:,d_idx),kr2_);
                    end


                end
                % Sigma is individual (regardless of ARD) because of missing values.
                kr2_sum = Rm*kr2_;
                
                krkr=[];
                %[Rkrkr, IND] =
                %premultiplication(Rm,kr,size(eFact{update_mode},2)); % Not
                %used...
                Rkrkr = []; IND = [];
                
                if ~isempty(eFact2pairwise{end})
                    if iscell(eNoise)
                        Rkrkr = bsxfun(@times,eFact2pairwise{ind(1)}, eNoise{ind(1)});
                        for i = 2:length(ind)
                            Rkrkr = krprod(bsxfun(@times,...
                                eFact2pairwise{ind(i)}, eNoise{ind(i)})...
                                , Rkrkr);
                        end
                        
                    else
                        Rkrkr = eFact2pairwise{ind(1)};
                        for i = 2:length(ind)
                            Rkrkr = krprod(eFact2pairwise{ind(i)}, Rkrkr);
                        end
                    end
                    Rkrkr = Rm*Rkrkr;
               end
                
            else
                
                if iscell(eNoise)
                    % If noise is present, then kr'*kr will have the noise
                    % variance multiplied twice.
                    noise_ = eNoise{ind(1)};
                    for i = 2:length(ind)
                        noise_ = krprod(eNoise{ind(i)}, noise_);
                    end
                    kr = bsxfun(@rdivide, kr, sqrt(noise_));
                end
                
                %krkr=kr'*kr; %% This is wrong, as it does not have the
                %variance! (Which is an issue if not all factors are
                %univariate...)
                krkr = ones(D,D);
                for i = ind
                    krkr = krkr .* eFact2{i};
                end
                Rkrkr = []; IND = [];
                
                %kr2_sum=sum(kr2_,1);
                kr2_sum=diag(krkr)'; %This way we do not need to calculate (or store) eFact2pairwise, when there is no missing data..
                
                
            end
            
            % Inference specific sufficient stats
            if iscell(eNoise)
                eNoise = eNoise{update_mode}; 
                % From here, only the specific noise mode is needed
            end
            self.calcSufficientStats(kr2_sum, eNoise);
            
            lb=self.lowerbound*ones(self.factorsize(1),1);
            ub=self.upperbound*ones(self.factorsize(1),1);
            for rep = 1:self.opt_options.hals_updates % Number of HALS updates
                % Fixed or permute update order
                if self.opt_options.permute
                    dOrder = randperm(self.factorsize(2));
                else
                    dOrder = 1:self.factorsize(2);
                end
                
                for d = dOrder
                    not_d=1:self.factorsize(2);
                    not_d(d)=[];
                    self.updateComponent(d, not_d, lb, ub, ...
                            Xmkr, eNoise, ...
                            krkr, Rkrkr)                   
                end
            end
            
        end
        
        function calcSufficientStats(self, kr2_sum, eNoise)
            % Calculate the variance of each element (note the covariance
            % between elements is zero per definition).
            if any(strcmpi(self.inference_method,{'variational','sampling'}))
                
                self.factor_sig2 = 1./bsxfun(@plus, bsxfun(@times, kr2_sum, eNoise),...
                    self.hyperparameter.getExpFirstMoment(self.factorsize));
                
                assert(~any(isinf(self.factor_sig2(:))),'Infinite sigma value?') % Sanity check
                assert(all(self.factor_sig2(:)>=0),'Variance was negative!')
                
            else
                
            end
        end
        
        function result = log_psi_func(self, t)
            result = -0.5*t.^2-0.5*log(2*pi);
        end
        
        function [mu] = calculateNormalMean(self, d, not_d, Xmkr, eNoise, krkr, Rkrkr)
            % Calculate the normal mean (mu) of the component, which is
            % needed to determined the mean value of the truncated normal
            % distribution.  
            if self.data_has_missing
                D= size(Xmkr,2);
                IND = D*(d-1)+not_d;
                mu = (Xmkr(:,d)-(sum(Rkrkr(:,IND).*self.factor(:,not_d),2)))...
                    .*eNoise.*self.factor_sig2(:,d);
            else
                mu= (Xmkr(:,d)-self.factor(:,not_d)*krkr(not_d,d))...
                    .*eNoise.*self.factor_sig2(:,d);
            end
            assert(~any(isinf(mu(:))),'Infinite mean value?')
        end
        
        function updateComponent(self,d, not_d, lb, ub, Xmkr, eNoise, krkr, Rkrkr)
            % Update the d'th component conditioned on knowning all other
            % components.
            mu = self.calculateNormalMean(d, not_d, Xmkr, eNoise, krkr, Rkrkr);
            self.factor_mu(:,d) = mu;
            
            % Update d'th component using...
            if strcmpi(self.inference_method, 'variational')
                % Variational Bayesian Inference
                if all(size(lb) == size(self.factor_sig2(:,d)))
                    [self.logZhatOUT(:,d), ~ , self.factor(:,d), self.factor_var(:,d) ] = ...
                        truncNormMoments_matrix_fun(lb, ub, mu , self.factor_sig2(:,d));
                else
                    [self.logZhatOUT(:,d), ~ , self.factor(:,d), self.factor_var(:,d) ] = ...
                        truncNormMoments_matrix_fun(lb, ub, mu , repmat(self.factor_sig2(:,d),length(mu),1));
                end
                self.factor_var(~(self.factor_var(:,d)>=0),d) = eps; % potential fix? what is Hore et al. doing?
                assert(all(self.factor_var(:,d)>=0))
                
            elseif strcmpi(self.inference_method, 'sampling')
                % Gibbs Sampling
                sig = sqrt(self.factor_sig2(:,d));
                self.factor(:,d) = trandn( (lb-mu)./sig, (ub-mu)./sig ).*sig+mu;

                self.factor_var = 0; % The variance of 1 sample is zero
                self.logZhatOUT(:,d) = truncNorm_logZ(lb, ub, mu , self.factor_sig2(:,d));
            end
        end
        
    end
end

