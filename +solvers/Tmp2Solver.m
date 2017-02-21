classdef Tmp2Solver < solvers.NlpSolver
    %% Tmp2Solver - Calls the MinConf_TMP solver
    % A clean up of TmpSolver.
    %
    % An object oriented framework based on the original minConf solver
    % available at: https://www.cs.ubc.ca/~schmidtm/Software/minConf.html
    %
    % Solves bounded non-linear optimization problems:
    %
    %   min_x { f(x) : bL <= x <= bU
    %
    % The solver has been modified to support a nlp model as primary
    % argument. Note that the function 'obj' has to be defined for the nlp
    % object and must return the objective function value, the gradient and
    % the hessian at x. The number of output arguments must also be
    % variable.
    %
    % The 'method' property determines the way the descent direction is
    % computed. It can either be:
    %
    %   * 'minres': the true hessian of the objective function is used and
    %   must be an ouput argument of nlp's obj function. It must also be a
    %   Spot operator and has to be symmetric as MinRes will be used.
    %
    %   * 'lsqr': the true hessian of the objective function is used and
    %   must be an ouput argument of nlp's obj function. It must also be a
    %   Spot operator and has to be symmetric as LSQR will be used.
    %
    %   * 'newton': the true hessian of the objective function is used an
    %   must be an ouput argument of nlp's obj function. It has to be an
    %   explicit matrix.
    %
    %   * 'lbfgs': the BFGS approximation of the hessian is used, but with
    %   limited memory.
    %
    %   * 'bfgs': the BFGS approximation of the hessian is used.
    %
    %   * 'sd': the direction is simply the steepest descent.
    %
    %   * 'pcg': call MATLAB's pcg() on Hx = -g, where H must be positive
    %   definite.
    %
    % The possibility of using numerical derivatives has been removed.
    % Removed cubic interpolation from linesearch.
    %
    % Original documentation follows:
    % ---------------------------------------------------------------------
    % function [x,f] = minConF_TMP(funObj,x,LB,UB,options)
    %
    % Function for using Two-Metric Projection to solve problems of the
    % form:
    %   min funObj(x)
    %   s.t. LB_i <= x_i <= UB_i
    %
    %   @funObj(x): function to minimize (returns gradient as second
    %   argument)
    %
    %   options:
    %       verbose: level of verbosity (0: no output, 1: final, 2: iter
    %       (default), 3: debug)
    %       aOptTol: tolerance used to check for progress (default: 1e-7)
    %       maxIter: maximum number of calls to funObj (default: 250)
    %       numDiff: compute derivatives numerically (0: use user-supplied
    %       derivatives (default), 1: use finite differences, 2: use
    %       complex differentials)
    
    
    properties (SetAccess = private, Hidden = false)
        suffDec;
        maxIterLS; % Maximal number of iterations during linesearch
        method; % How to compute the descent direction
        fid;
        krylOpts;
        
        descDirFunc;
        lsFunc;
    end % private properties
    
    properties (Hidden = true, Constant)
        LOG_HEADER = {'Iteration','FunEvals', 'Step Length', ...
            'Function Val', '||Pg||', 'g''*d'};
        LOG_FORMAT = '%10s %10s %15s %15s %15s %15s\n';
        LOG_BODY = '%10d %10d %15.5e %15.5e %15.5e %15.5e\n';
    end % constant properties
    
    
    methods (Access = public)
        
        function self = Tmp2Solver(nlp, varargin)
            %% Constructor
            % Inputs:
            %   - nlp: a subclass of a nlp model containing the 'obj'
            %   function that returns variable output arguments among the
            %   following: objective function, gradient and hessian at x.
            %   The hessian can be a Spot operator if it is too expensive
            %   to compute. The method also supports a L-BFGS approximation
            %   of the hessian.
            %   - varargin (optional): the various parameters of the
            %   algorithm
            
            % Gathering optional arguments and setting default values
            p = inputParser;
            p.KeepUnmatched = true;
            p.PartialMatching = false;
            p.addParameter('suffDec', 1e-4);
            p.addParameter('method', 'pcg');
            p.addParameter('fid', 1);
            p.addParameter('maxIterLS', 50); % Max iters for linesearch
            p.addParameter('projLS', true); % Projected line search
            p.parse(varargin{:});
            
            self = self@solvers.NlpSolver(nlp, p.Unmatched);
            
            self.suffDec = p.Results.suffDec;
            self.maxIterLS = p.Results.maxIterLS;
            self.fid = p.Results.fid;
            
            % Setting the descent direction computation function
            if strcmp(p.Results.method, 'lsqr')
                % LSQR - NlpModel must be a LeastSquaresModel!
                if  ~isa(nlp, 'model.LeastSquaresModel')
                    error(['nlp must be a model.LeastSquaresModel in', ...
                        ' order to use LSQR.']);
                end
                self.descDirFunc = @(self, x, g, H, working) ...
                    lsqr_spot(self.nlp.A(:, working), self.nlp.b, ...
                    self.krylOpts) - x(working);
            elseif strcmp(p.Results.method, 'lsmr')
                % LSMR - NlpModel must be a LeastSquaresModel!
                if  ~isa(nlp, 'model.LeastSquaresModel')
                    error(['nlp must be a model.LeastSquaresModel in', ...
                        ' order to use LSMR.']);
                end
                self.descDirFunc = @(self, x, g, H, working) ...
                    lsmr_spot(self.nlp.A(:, working), self.nlp.b, ...
                    self.krylOpts) - x(working);
            elseif strcmp(p.Results.method, 'minres')
                % MinRes
                self.descDirFunc = @(self, x, g, H, working) ...
                    minres_spot(H(working, working), -g(working), ...
                    self.krylOpts);
            else
                % Default to PCG
                self.descDirFunc = @(self, x, g, H, working) ...
                    self.callPcg(x, working, H, g);
            end
            
            % Setting MinRes, LSQR & LSMR's parameters
            self.krylOpts.etol = self.aOptTol;
            self.krylOpts.rtol = self.aOptTol;
            self.krylOpts.atol = self.aOptTol;
            self.krylOpts.btol = self.aOptTol;
            self.krylOpts.shift = 0;
            self.krylOpts.show = false;
            self.krylOpts.check = false;
            self.krylOpts.itnlim = self.nlp.n;
            
            import utils.PrintInfo;
            
            if p.Results.projLS
                import linesearch.projectedArmijo;
                self.lsFunc = @(x, f, g, d) ...
                    linesearch.projectedArmijo(x, f, g, d);
            else
                % Project the step first!
                import linesearch.armijo;
                self.lsFunc = @(x, f, g, d) ...
                    self.projectThenArmijo(x, f, g, d);
            end
        end % constructor
        
        function self = solve(self)
            %% Solve
            % Solves the problem defined in the nlp model that was passed
            % as an argument to the constructor. Computes the descent
            % direction according to the 'method' parameter.
            
            self.solveTime = tic;
            self.iStop = self.EXIT_NONE;
            self.iter = 1;
            self.nlp.resetCounters();
            
            printObj = utils.PrintInfo('Tmp');
            
            % Output Log
            if self.verbose >= 2
                extra = containers.Map( ...
                    {'suffDec', 'method', 'corrections', 'damped', ...
                    'maxIterLS'}, ...
                    {self.suffDec, self.method, self.corrections, ...
                    self.damped, self.maxIterLS});
                printObj.header(self, extra);
                self.printf(self.LOG_FORMAT, self.LOG_HEADER{:});
            end
            
            % Make sure initial point is feasible
            x = self.project(self.nlp.x0);
            % Compute the objective function, the gradient and the hessian
            [f, g, H] = self.nlp.obj(x);
            
            % Relative stopping tolerance
            self.rOptTol = self.aOptTol * norm(g);
            self.rFeasTol = self.aFeasTol * abs(f);
            
            fOld = inf;
            gtd = inf;
            t = 1;
            
            %% Main loop
            while ~self.iStop % self.iStop == 0
                
                % Compute working set (free variables)
                working = self.working(x, g);
                % Stopping criteria is the norm of the free vars. gradient
                pgnrm = norm(g(working));
                
                % Output log
                self.nObjFunc = self.nlp.ncalls_fobj + ...
                    self.nlp.ncalls_fcon;
                if self.verbose >= 2
                    fprintf(self.LOG_BODY, self.iter, self.nObjFunc, ...
                        t, f, pgnrm, gtd);
                end
                
                % Checking various stopping conditions, exit if true
                if isempty(working)
                    self.iStop = self.EXIT_ALL_BOUND;
                elseif pgnrm <= self.rOptTol + self.aOptTol
                    self.iStop = self.EXIT_OPT_TOL;
                    % Check for lack of progress
                elseif abs(f - fOld) < self.rFeasTol + self.aFeasTol
                    self.iStop = self.EXIT_FEAS_TOL;
                elseif self.nObjFunc > self.maxEval
                    self.iStop = self.EXIT_MAX_EVAL;
                elseif self.iter >= self.maxIter
                    self.iStop = self.EXIT_MAX_ITER;
                elseif toc(self.solveTime) >= self.maxRT
                    self.iStop = self.EXIT_MAX_RT;
                end
                
                if self.iStop % self.iStop ~= 0
                    break;
                end
                
                % Compute step direction
                d = zeros(self.nlp.n, 1);
                % Solve H * d = -g on the working variables
                d(working) = self.descDirFunc(self, x, g, H, working);
                
                % Check that progress can be made along the direction
                gtd = g' * d;
                if gtd > -self.aOptTol * norm(g) * norm(d) - self.aOptTol
                    self.iStop = self.EXIT_DIR_DERIV;
                    % Leave now
                    break;
                end
                
                % Check sufficient decrease condition and do a linesearch
                fOld = f;
                [x, f, failed, t] = self.lsFunc(x, f, g, d);
                
                % Update g and H at new x
                [~, g, H] = self.nlp.obj(x);
                
                % Exit if line search failed
                if failed
                    self.iStop = self.EXIT_MAX_ITER_LS;
                    pgnrm = norm(g(working));
                    break;
                end
                
                self.iter = self.iter + 1;
            end % main loop
            
            self.x = x;
            self.fx = f;
            self.pgNorm = pgnrm;
            
            self.nObjFunc = self.nlp.ncalls_fobj + self.nlp.ncalls_fcon;
            self.nGrad = self.nlp.ncalls_gobj + self.nlp.ncalls_gcon;
            self.nHess = self.nlp.ncalls_hvp + self.nlp.ncalls_hes;
            
            %% End of solve
            self.solveTime = toc(self.solveTime);
            % Set solved attribute
            self.isSolved();
            
            printObj.footer(self);
        end % solve
        
        function printf(self, varargin)
            %% Printf - prints variables arguments to a file
            fprintf(self.fid, varargin{:});
        end
        
    end % public methods
    
    
    methods (Access = private)
        
        function x = project(self, x)
            %% Project - project x on the bounds
            % Upper and lower bounds are defined in nlp model
            x = min(max(x, self.nlp.bL), self.nlp.bU);
        end
        
        function working = working(self, x, g)
            %% Working - compute set of 'working' variables
            % true  = variable didn't reach its bound and can be improved
            
            % Find binding set
            working = ~((x <= self.nlp.bL & g >= 0) | ...
                (x <= self.nlp.bU & g <= 0));
        end
        
        function d = callPcg(self, ~, working, g, H)
            %% CallPcg
            % Simple wrapper function to get rid of PCG's output message
            % Second argout disables message
            [d(working), ~] = pcg(H(working, working), -g(working), ...
                self.rOptTol + self.aOptTol, self.krylOpts.itnlim);
        end
        
        function [x, f, failed, t] = projectThenArmijo(self, x, f, g, d)
            %% ProjectThenArmijo
            % Project the descent direction, then do Armijo backtracking.
            d = self.project(x - d) - x;
            [x, f, failed, t] = linesearch.armijo(x, f, g, d);
        end
    end % private methods
    
end % class