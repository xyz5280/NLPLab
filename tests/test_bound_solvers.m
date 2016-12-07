clc;
clear all;
close all;

%% Format
HEADER = {'Solver', '#iter', '#f', '#g', '#H', '|Pg|', ...
    '|x*-x|', 'RT'};
HEADER_FORMAT = ['%25s', repmat('%10s ', 1, 7), '\n'];
BODY_FORMAT = '%25s %10d %10d %10d %10d %10.1e %10.1e %10.1e\n';
outInfo = {};

%% Seting MATLAB's path
addpath('~/Masters/NLPlab');
addpath('~/Masters/logging4matlab/');
addpath('~/Masters/Spot');
addpath('~/Masters/optimization/lbfgsb');
addpath('~/Masters/optimization/box_project');

%% Building the model
import model.QpModel;
% Quadratic objective function, upper and lower bounds
m = 20;
n = m;
Q = randi(3, m, n);
Q = Q' * Q;
c = -round(10 * rand(n, 1));
bL = -1 * ones(n, 1);
bU = 5 * ones(n, 1);
bU(1:3:end) = 1;
x0 = zeros(n, 1);
cL = -inf(n, 1);
cU = inf(n, 1);
A = [];
quadModel = QpModel('', x0, cL, cU, bL, bU, A, c, Q);
% For the PQN & SPG solvers, we need a projection function
import model.BoundedQpModel;
bQuadModel = BoundedQpModel('', x0, bL, bU, c, Q);

%% MATLAB's quadprog is the reference solution
xRef = quadprog(Q, c, [], [], [], [], bL, bU);

%% Solve using TMP
import solvers.TmpSolver;
solver = TmpSolver(quadModel, 'method', 'pcg', 'aOptTol', 1e-10, ...
    'aFeasTol', 1e-15);
solver = solver.solve();

nrmSol = norm(xRef - solver.x);
outInfo{end + 1} = sprintf(BODY_FORMAT, class(solver), solver.iter, ...
    solver.nObjFunc, solver.nGrad, solver.nHess, solver.pgNorm, nrmSol, ...
    solver.solveTime);

%% Solve using SPG (works only if prob is quadratic)
import solvers.SpgSolver;
solver = SpgSolver(bQuadModel, 'aOptTol', 1e-10, 'aFeasTol', 1e-15);
solver = solver.solve();

nrmSol = norm(xRef - solver.x);
outInfo{end + 1} = sprintf(BODY_FORMAT, class(solver), solver.iter, ...
    solver.nObjFunc, solver.nGrad, solver.nHess, solver.pgNorm, nrmSol, ...
    solver.solveTime);

%% Solve using PQN
import solvers.PqnSolver;
solver = PqnSolver(bQuadModel, 'hess', 'exact', 'aOptTol', 1e-10, ...
    'progTol', 1e-15, 'aFeasTol', 1e-15);
solver = solver.solve();

nrmSol = norm(xRef - solver.x);
outInfo{end + 1} = sprintf(BODY_FORMAT, class(solver), solver.iter, ...
    solver.nObjFunc, solver.nGrad, solver.nHess, solver.pgNorm, nrmSol, ...
    solver.solveTime);

%% Solve using bcflash
import solvers.BcflashSolver;
solver = BcflashSolver(quadModel, 'aOptTol', 1e-10, 'aFeasTol', 1e-15);
solver = solver.solve();

nrmSol = norm(xRef - solver.x);
outInfo{end + 1} = sprintf(BODY_FORMAT, class(solver), solver.iter, ...
    solver.nObjFunc, solver.nGrad, solver.nHess, solver.pgNorm, nrmSol, ...
    solver.solveTime);

%% Solve using L-BFGS-B
import solvers.LbfgsbSolver;
solver = LbfgsbSolver(quadModel, 'aOptTol', 1e-10, 'aFeasTol', 1e-15, ...
    'maxIter', 5e2);
solver = solver.solve();

nrmSol = norm(xRef - solver.x);
outInfo{end + 1} = sprintf(BODY_FORMAT, class(solver), solver.iter, ...
    solver.nObjFunc, solver.nGrad, solver.nHess, solver.pgNorm, nrmSol, ...
    solver.solveTime);

%% Printing
fprintf('\n\n\n');
fprintf(HEADER_FORMAT, HEADER{:});
for s = outInfo
    fprintf(s{1});
end