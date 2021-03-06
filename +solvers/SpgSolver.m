classdef SpgSolver < solvers.NlpSolver
    %% SpgSolver - Calls the MinConf_SPG solver
    % Original documentation follows:
    % ---------------------------------------------------------------------
    % function [x,f,self.nObjFunc,self.nProj] = minConf_SPG(funObj,x,
    % funProj, options)
    %
    % Function for using Spectral Projected Gradient to solve problems of
    % the form
    %   min funObj(x) s.t. x in C
    %
    %   @funObj(x): function to minimize (returns gradient as second
    %               argument)
    %   @funProj(x): function that returns projection of x onto C
    %
    %   options:
    %       verbose: level of verbosity (0: no output, 1: final,
    %                     2: iter (default), 3: debug)
    %       optTol: tolerance used to check for optimality (default: 1e-5)
    %       progTol: tolerance used to check for lack of progress (default:
    %                1e-9)
    %       maxIter: maximum number of calls to funObj (default: 500)
    %       numDiff: compute derivatives numerically (0: use user-supplied
    %       derivatives (default), 1: use finite differences, 2: use
    %                                 complex differentials)
    %       suffDec: sufficient decrease parameter in Armijo condition
    %       (default: 1e-4)
    %       interp: type of interpolation (0: step-size halving, 1:
    %       quadratic, 2: cubic)
    %       memory: number of steps to look back in non-monotone Armijo
    %       condition
    %       useSpectral: use spectral scaling of gradient direction
    %       (default: 1)
    %       projectLS: backtrack along projection Arc (default: 0)
    %       testOpt: test optimality condition (default: 1)
    %       feasibleInit: if 1, then the initial point is assumed to be
    %       feasible
    %       bbType: type of Barzilai Borwein step (default: 1)
    %
    %   Notes:
    %       - if the projection is expensive to compute, you can reduce the
    %           number of projections by setting self.testOpt to 0


    properties (SetAccess = protected, Hidden = false)
        % Projection calls counter
        nProj;
        suffDec;
        memory;
        useSpectral;
        projectLS;
        testOpt;
        bbType;
        maxIterLS;
        fid;
    end % private properties

    properties (Hidden = true, Constant)
        LOG_HEADER = { ...
            'iter', 'f(x)', '#fEvals', '#Proj', 'Step Length', 'Time'};
        LOG_FORMAT = '%5s  %13s  %7s  %5s  %13s  %9s\n';
        LOG_BODY = '%5d  %13.6d  %7d  %5d  %13.6e  %9f\n';
        LOG_HEADER_OPT = { ...
            'iter', 'f(x)', '||Pg||', '#fEvals', '#Proj', 'Step Length', 'Time'};
        LOG_FORMAT_OPT = '%5s  %13s  %13s  %7s  %5s  %13s  %9s\n';
        LOG_BODY_OPT = '%5d  %13.6e  %13.6d  %7d  %5d  %13.6e  %9f\n';
    end % constant properties


    methods (Access = public)
        
        function self = SpgSolver(nlp, varargin)
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

            if ~ismethod(nlp, 'project')
                error('nlp doesn''t contain a project method');
            end

            % Gathering optional arguments and setting default values
            p = inputParser;
            p.PartialMatching = false;
            p.KeepUnmatched = true;
            p.addParameter('suffDec', 1e-4);
            p.addParameter('memory', 10);
            p.addParameter('useSpectral', 1);
            p.addParameter('projectLS', 0);
            p.addParameter('testOpt', 1);
            p.addParameter('bbType', 1);
            p.addParameter('fid', 1);
            p.addParameter('maxIterLS', 50); % Max iters for linesearch

            p.parse(varargin{:});

            self = self@solvers.NlpSolver(nlp, p.Unmatched);

            self.suffDec = p.Results.suffDec;
            self.memory = p.Results.memory;
            self.useSpectral = p.Results.useSpectral;
            self.projectLS = p.Results.projectLS;
            self.testOpt = p.Results.testOpt;
            self.bbType = p.Results.bbType;
            self.maxIterLS = p.Results.maxIterLS;
            self.fid = p.Results.fid;

            import utils.PrintInfo;
            import linesearch.nonMonotoneArmijo;
        end % constructor

        function self = solve(self)
            %% Solve using MinConf_SPG

            self.solveTime = tic;
            self.iStop = self.EXIT_NONE;
            self.nProj = 0;
            self.iter = 1;
            self.nlp.resetCounters();

            printObj = utils.PrintInfo('Spg');

            % Output Log
            if self.verbose >= 2
                % Printing header
                extra = containers.Map( ...
                    {'suffDec', 'memory', 'useSpectral', 'projectLS', ...
                    'testOpt', 'bbType', 'maxIterLS'}, ...
                    {self.suffDec, self.memory, self.useSpectral, ...
                    self.projectLS, self.testOpt, self.bbType, ...
                    self.maxIterLS});
                printObj.header(self, extra);

                if self.testOpt
                    self.printf(self.LOG_FORMAT_OPT, ...
                        self.LOG_HEADER_OPT{:});
                else
                    self.printf(self.LOG_FORMAT, ...
                        self.LOG_HEADER{:});
                end
            end

            % Evaluate Initial Point
            x = self.project(self.nlp.x0);
            [f, g] = self.nlp.obj(x);

            % Relative stopping tolerance
            self.gNorm0 = norm(self.gpstep(x, g));
            rOptTol = self.rOptTol * self.gNorm0;
            rFeasTol = self.rFeasTol * abs(f);

            % Optionally check optimality
            pgnrm = 0;
            if self.testOpt
                if self.gNorm0 < rOptTol + self.aOptTol
                    self.iStop = 1; % will bypass main loop
                end
            end

            %% Main loop
            while ~self.iStop % self.iStop == 0
                % Compute Step Direction
                if self.iter == 1 || ~self.useSpectral
                    alph = 1;
                else
                    y = g - gOld;
                    s = x - xOld;
                    alph = self.bbstep(s, y);
                    if alph <= 1e-10 || alph > 1e10 || isnan(alph)
                        alph = 1;
                    end
                end

                % Descent direction
                d = self.descentdirection(alph, x, g);
                fOld = f;
                xOld = x;
                gOld = g;

                % Compute Projected Step
                if ~self.projectLS
                    d = self.gpstep(x, -d); % project(x + d), d = -alph*g
                end

                % Check that Progress can be made along the direction
                gtd = g' * d;
                if gtd > -self.aFeasTol * norm(g) * norm(d) - self.aFeasTol
                    self.iStop = self.EXIT_DIR_DERIV;
                    % Leaving now saves some processing
                    break;
                end

                % Select Initial Guess to step length
                if self.iter == 1
                    t = min(1, 1 / norm(g, 1));
                else
                    t = 1;
                end

                % Compute reference function for non-monotone condition
                if self.memory <= 1
                    funRef = f;
                else
                    if self.iter == 1
                        fOldVals = repmat(-inf, [self.memory 1]);
                    end
                    if self.iter <= self.memory
                        fOldVals(self.iter) = f;
                    else
                        fOldVals = [fOldVals(2:end); f];
                    end
                    funRef = max(fOldVals);
                end

                % Evaluate the Objective and Gradient at the Initial Step
                if self.projectLS
                    xNew = self.project(x + t * d);
                else
                    xNew = x + t * d;
                end

                [fNew, gNew] = self.nlp.obj(xNew);
                
                [xNew, fNew, gNew, t, ~] = self.backtracking(x, ...
                    xNew, f, fNew, g, gNew, d, t, funRef);

                % Take Step
                x = xNew;
                f = fNew;
                g = gNew;

                time = toc(self.solveTime);
                if self.testOpt
                    pgnrm = norm(self.gpstep(x, g));
                    % Output Log with opt. cond.
                    if self.verbose >= 2
                        self.nObjFunc = self.nlp.ncalls_fobj + ...
                            self.nlp.ncalls_fcon;
                        fprintf(self.fid, self.LOG_BODY_OPT, self.iter, ...
                            f, pgnrm, self.nObjFunc, self.nProj, t, time);
                    end
                else
                    % Output Log without opt. cond.
                    if self.verbose >= 2
                        self.nObjFunc = self.nlp.ncalls_fobj + ...
                            self.nlp.ncalls_fcon;
                        fprintf(self.fid, self.LOG_BODY, self.iter, ...
                            f, self.nObjFunc, self.nProj, t, time);
                    end
                end

                % Check optimality
                if self.testOpt
                    if pgnrm < rOptTol + self.aOptTol
                        self.iStop = self.EXIT_OPT_TOL;
                    end
                end
                if max(abs(t * d)) < self.aFeasTol * norm(d) + ...
                        self.aFeasTol
                    self.iStop = self.EXIT_DIR_DERIV;
                elseif abs(f - fOld) < rFeasTol + self.aFeasTol
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

    methods (Access = protected)

        function d = descentdirection(~, alph, ~, g)
            %% DescentDirection - Compute the search direction
            %  Inputs:
            %  - alph: the Barzilai-Borwein steplength
            %  - g: objective gradient
            d = -alph * g;
        end

        function alph = bbstep(self, s, y)
            %% BBStep - Compute the spectral steplength
            %  Inputs:
            %  - s: step between the two last iterates
            %  - y: difference between the two last gradient

            if self.bbType == 1
                alph = (s' * s) / (s' * y);
            else
                alph = (s' * y) / (y' * y);
            end
        end

        function s = gpstep(self, x, g)
            %% GPStep - computing the projected gradient
            % Inputs:
            %   - x: current point
            %   - g: gradient at x
            % Output:
            %   - s: projected gradient
            % Calling project to increment projection counter
            s = self.project(x - g) - x;
        end

        function z = project(self, x)
            %% Project - projecting x on the constraint set
            [z, solved] = self.nlp.project(x);
            if ~solved
                % Propagate throughout the program to exit
                self.iStop = self.EXIT_PROJ_FAILURE;
            end
            self.nProj = self.nProj + 1;
        end

        function [xNew, fNew, gNew, t, failed] = backtracking(self, ...
                x, xNew, f, fNew, g, gNew, d, t, funRef)
            % Backtracking Line Search
            failed = false;
            iterLS = 1;
            while fNew > funRef + self.suffDec* g' * (xNew - x)
                t = t / 2;

                % Check whether step has become too small
                if max(abs(t * d)) < self.aFeasTol * norm(d) ...
                        || t == 0 || iterLS > self.maxIterLS
                    failed = true;
                    t = 0;
                    xNew = x;
                    fNew = f;
                    gNew = g;
                    return;
                end

                if self.projectLS
                    % Projected linesearch
                    xNew = self.project(x + t * d);
                else
                    xNew = x + t * d;
                end

                [fNew, gNew] = self.nlp.obj(xNew);
                iterLS = iterLS + 1;
            end
        end % backtracking

    end % private methods

end % class