"""
Train the model that the genotyper uses to make genotype calls.

The model is trained with a features file equivalent to "samples/SAMPLE/gt_features.tab" (where SAMPLE is the sample
name). The features table can generated by running the genotyper pipeline up to "gt_call_sample_merge" for a sample
that was setup for training (desired features and Illumina sequence data). The "features" configuration option tells
the pipeline where to find this file.

The class labels for each variant are input in another file with one line per variant and in the same order they appear
in the features table. Class labels are "HOM_ALT", "HET", and "HOM_REF". The "labels" configuration option tells the
pipeline where to find this file.

K-fold cross-validation (CV) is performed twice: Once to optimize hyper-parameters (parameters to the model training
method that are not learned by the model), and once to estimate error. These steps are the "tune" and "test"
cross-validation sets. The data is split first for testing (where k-1 sets are used for training, and 1 set is used for
testing). Within the test-training set, the variants are split again into k sets where k-1 sets are used to train the
model with a given set of hyper-parameters and 1 set is used for testing the performance given the hyper-parameters.
The optimal hyper-parameters are chosen, the whole training set is used to train the model, and it is tested against the
held-out fold from the test set. Both cross-validations are iterated over each fold so that each fold has a turn as the
test set.

The whole data set is split again to apply cross-validation to learn the hyper-parameters for the final
training set. The optimal set of hyper-parameters is then used to train the final model on all the data. Since this
model cannot be evaluated with held-out data, we use the results of the test cross-validation experiment to estimate it.
"""

import numpy as np
import os
import pandas as pd

from sklearn.externals import joblib
from sklearn.model_selection import GridSearchCV
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

if not 'INCLUDE_SNAKEFILE' in globals():
    include: 'include.snakefile'

from smrtsvlib import ml


##############
### Config ###
##############

with open(config.get('learn_config', 'gt_learn.json'), 'r') as config_in:
    CONFIG_LEARN = json.load(config_in)


####################
### Declarations ###
####################

# Number of cross-validation folds
FOLDS_K = int(CONFIG_LEARN.get('folds', '8'))

# Callable threshold a a sum of depth over ref and alt breakpoints. This is a typical cutoff for choosing NO_CALL
# variants.
CALLABLE_THRESHOLD = int(CONFIG_LEARN.get('callable_threshold', '4'))

# Hyper-parameter grid for grid-search CV
PARAM_GRID = [
    {'kernel': ['rbf'], 'gamma': [1e-1, 5.5e-2, 1e-2, 5.5e-3, 1e-3], 'C': [10, 100, 500, 1000, 5000, 5500]}
]

# Get a list of samples and the training sample
FEATURE_SAMPLES = sorted(CONFIG_LEARN.get('features').keys())
FEATURE_SAMPLE_TRAIN = CONFIG_LEARN.get('train_feature')

# Get other parameters
CONFIG_LEARN_PARAMS = CONFIG_LEARN.get('params', {})

# Param retain_nocall: Train with No-call variants if True. Otherwise, discard no-call variants before training.
PARAM_RETAIN_NOCALL = CONFIG_LEARN_PARAMS.get('retain_nocall', 'False').lower() in ('true', 't', '1')

# Param balance_calls: Randomly down-sample variants so that call types are perfectly balanced in all folds.
PARAM_BALANCE_CALLS = CONFIG_LEARN_PARAMS.get('balance_calls', 'False').lower() in ('true', 't', '1')


#############
### Rules ###
#############

localrules: gt_learn, gt_learn_link_stats, gt_learn_model_link_features, gt_learn_model_link_train_array


#
# Evaluate and train
#

# gt_learn
#
# Train predictor and scaler, and get CV stats.
rule gt_learn:
    input:
        predictor='model/predictor.pkl',
        scaler='model/scaler.pkl',
        tab='cv/stats.tab'


#
# Train model
#

# gt_learn_model_train
#
# Train the model that will be used for predictions. Save the whole grid-search CV object, which includes the model.
rule gt_learn_model_train:
    input:
        X_npy='model/X.npy',
        y_npy='model/y.npy',
        feat_tab='model/features.tab'
    output:
        predictor='model/predictor.pkl',
        tab='model/predictor_stats.tab'
    params:
        k=FOLDS_K,
        threads=4,
        retain_nocall=PARAM_RETAIN_NOCALL
    run:

        # Load data
        X = np.load(input.X_npy)
        y = np.load(input.y_npy)

        features = pd.read_csv(input.feat_tab, sep='\t', header=0)

        # Get variants selected for testing (some may have been left out when balancing calls for each SV type)
        train_indices = features.index[features['SELECTED']]

        # Filter no-call if set
        if not params.retain_nocall:
            callable_set = set(features.index[features['CALLABLE']])
            train_indices = [i for i in train_indices if i in callable_set]

        # Subset
        X = X[train_indices, :]
        y = y[train_indices]

        features = features.iloc[train_indices]
        features.reset_index(inplace=True)

        # Optimize hyper-parameters and fit the best model
        clf = GridSearchCV(
            estimator=SVC(C=1),
            param_grid=PARAM_GRID,
            scoring='accuracy',
            cv=ml.cv_set_iter(ml.stratify_folds(features['STRATIFIED'], params.k)),
            refit=False,
            error_score=0,
            n_jobs=params.threads
        )

        clf.fit(X, y)

        # Train final model
        predictor = SVC(probability=True, **clf.best_params_)
        predictor.fit(X, y)

        # Write model
        joblib.dump(predictor, output.predictor)

        # Write stats
        ml.get_cv_score_table(clf).to_csv(output.tab, sep='\t', index=False)


#
# Test model by statified K-fold cross-validation
#

# gt_learn_get_stats
#
# Get stats array.
rule gt_learn_get_stats:
    input:
        tab=expand('cv/samples/{sample}/stats.tab', sample=FEATURE_SAMPLES),
        tab_pred=expand('cv/samples/{sample}/model_predict.tab', sample=FEATURE_SAMPLES)
    output:
        tab='cv/stats.tab'
    run:

        # Read accuracy for each sample
        accuracy_list = list()

        for sample in FEATURE_SAMPLES:
            acc = pd.read_csv('cv/samples/{}/stats.tab'.format(sample), sep='\t', header=0, usecols=('accuracy', 'subset'), index_col='subset', squeeze=True)
            acc.name = sample

            accuracy_list.append(acc)

        # Merge and write
        df = pd.concat(accuracy_list, axis=1).T
        df.index.name = 'sample'
        df.columns.name = None
        df.to_csv(output.tab, sep='\t', index=True, float_format='%.4f')

# gt_learn_cv_merge_predictions
#
# Merge predictions from CV with features.
rule gt_learn_cv_merge_predictions:
    input:
        tab_features='model/samples/{sample}/features.tab',
        tab_pred=expand('cv/samples/{{sample}}/folds/predict_{cv_set}.tab', cv_set=range(FOLDS_K))
    output:
        tab_pred='cv/samples/{sample}/model_predict.tab',
        tab_cross='cv/samples/{sample}/predict_prop.tab'
    run:

        # Read features
        df_features = pd.read_csv(input.tab_features, sep='\t', header=0)

        # Merge CV predictions
        df_pred = pd.concat(
            [
                pd.read_csv(
                    'cv/samples/{}/folds/predict_{}.tab'.format(wildcards.sample, cv_set),
                    sep='\t',
                    header=0,
                    index_col='INDEX'
                ) for cv_set in range(FOLDS_K)
            ],
            axis=0
        )

        df = pd.concat([df_features, df_pred], axis=1)
        df.sort_index(axis=0, inplace=True)

        # Write table
        df.to_csv(output.tab_pred, sep='\t', index=False)

        # Get crosstab
        df_cross = pd.crosstab(df['PREDICTION'], df['CALL'])

        for col in df_cross.columns:
            df_cross[col] /= sum(df_cross[col])

        df_cross.to_csv(output.tab_cross, sep='\t', float_format='%.2f')

# gt_learn_cv_merge_stats
#
# Merge stats.
rule gt_learn_cv_merge_stats:
    input:
        tab=expand('cv/samples/{{sample}}/folds/cv_{cv_set}.tab', cv_set=range(FOLDS_K))
    output:
        tab='cv/samples/{sample}/stats.tab'
    run:

        n_folds = len(input.tab)

        # Read tables
        df = pd.read_csv(input.tab[0], sep='\t', header=0, index_col='subset')

        # Get stats
        stats = np.asarray(df)  # For first table

        for index in range(1, n_folds):  # For other tables
            stats += np.asarray(pd.read_csv(input.tab[index], sep='\t', header=0, index_col='subset'))

        stats /= n_folds

        # Write
        pd.DataFrame(stats, index=df.index, columns=df.columns).to_csv(output.tab, sep='\t')

# gt_learn_cv_run
#
# Run cross-validation to test model performance on the data.
rule gt_learn_cv_run:
    input:
        X_npy='model/X.npy',
        y_npy='model/y.npy',
        scaler='model/scaler.pkl',
        cv_tab='cv/test_sets.tab',
        cv_nosel_tab='cv/test_sets_nosel.tab',
        feat_tab='model/features.tab',
        X_sample=expand('model/samples/{sample}/X.npy', sample=FEATURE_SAMPLES)
    output:
        tab_cv=expand('cv/samples/{sample}/folds/cv_{{cv_set}}.tab', sample=FEATURE_SAMPLES),
        tab_pred=expand('cv/samples/{sample}/folds/predict_{{cv_set}}.tab', sample=FEATURE_SAMPLES)
    params:
        k=FOLDS_K,
        threads=4,
        retain_nocall=PARAM_RETAIN_NOCALL
    run:

        cv_set = int(wildcards.cv_set)

        # Load data for model
        X = np.load(input.X_npy)
        y = np.load(input.y_npy)

        scaler = joblib.load(input.scaler)

        fold_array = np.loadtxt(input.cv_tab, np.int32, skiprows=1)
        fold_array_nosel = np.loadtxt(input.cv_nosel_tab, np.int32, skiprows=1)

        features = pd.read_csv(input.feat_tab, sep='\t', header=0)

        # Load data for samples to CV against
        # sample_list is a list of tuples with one list entry for each sample. The first element of each tuple
        # is the sample name, and the second is the scaled X matrix for that sample.
        sample_list = list()

        for sample in FEATURE_SAMPLES:
            sample_list.append((sample, np.load('model/samples/{}/X.npy'.format(sample))))

        # Get set of callable indices
        callable_set = set(features.index[features['CALLABLE']])

        # Subset data for this fold
        test_indices = fold_array[fold_array[:, 1] == cv_set, 0]
        train_indices = fold_array[fold_array[:, 1] != cv_set, 0]

        if not params.retain_nocall:
            train_indices = np.array([x for x in train_indices if x in callable_set])

        # Add variants that were not selected (for balancing SVCALLs)
        if fold_array_nosel.shape[0] > 0:
            test_indices_nosel = fold_array_nosel[fold_array_nosel[:, 1] == cv_set, 0]

            test_indices = np.concatenate([test_indices, test_indices_nosel], axis=0)
            test_indices = np.sort(test_indices, axis=0)

        # Subset test indices into variants that would be callable and those that would not be
        test_callable_indices = np.array([x for x in test_indices if x in callable_set])
        test_nocall_indices = np.array([x for x in test_indices if x not in callable_set])

        # Get an array of stratified labels and callable flag for each variant in this fold
        selection_labels = features.loc[train_indices].reset_index()['STRATIFIED']

        clf = GridSearchCV(
            estimator=SVC(),
            param_grid=PARAM_GRID,
            scoring='accuracy',
            cv=ml.cv_set_iter(ml.stratify_folds(selection_labels, params.k)),
            refit=False,
            error_score=0,
            n_jobs=params.threads
        )

        clf.fit(X[train_indices, :], y[train_indices])

        # Refit model with density estimation enabled
        predictor = SVC(probability=True, **clf.best_params_)
        predictor.fit(X[train_indices, :], y[train_indices])

        # Write scores and predictions for each sample
        for sample, X_sample in sample_list:

            # Write CV scores
            ml.get_cv_test_scores(
                predictor, X_sample, y,
                test_indices, test_callable_indices, test_nocall_indices
            ).to_csv('cv/samples/{}/folds/cv_{}.tab'.format(sample, wildcards.cv_set), sep='\t', index_label='subset')

            # Write predictions
            y_pred = pd.Series(predictor.predict(X_sample[test_indices]), index=test_indices)
            y_pred.name = 'PREDICTION'

            df_density = pd.DataFrame(
                predictor.predict_proba(X_sample[test_indices]),
                columns=predictor.classes_,
                index=test_indices
            )

            df_density = df_density.loc[:, ml.GT_LABELS]

            df_density = pd.concat([df_density, y_pred], axis=1)

            df_density.to_csv(
                'cv/samples/{}/folds/predict_{}.tab'.format(sample, wildcards.cv_set),
                sep='\t',
                index_label='INDEX'
            )

# gt_learn_cv_statify_k
#
# Split the variants into k sets stratified over variant type, genotype, and TRF overlap. The modified labels,
# output.labels_tab, are saved for reuse in cross-validation.
rule gt_learn_cv_statify_k:
    input:
        feat_tab='model/features.tab'
    output:
        cv_tab='cv/test_sets.tab',
        cv_tab_nosel='cv/test_sets_nosel.tab'
    params:
        k=FOLDS_K
    run:

        # Read data
        features = pd.read_csv(input.feat_tab, sep='\t', header=0)

        features_nosel = features.loc[~features['SELECTED']]
        features = features.loc[features['SELECTED']]

        # Stratify folds over labels
        fold_array = ml.stratify_folds(features['STRATIFIED'], params.k)

        if features_nosel.shape[0] > 0:
            fold_array_nosel = ml.stratify_folds(features_nosel['STRATIFIED'], params.k)
        else:
            fold_array_nosel = np.zeros((0, 2))

        # Write
        pd.DataFrame(fold_array, columns=('variant', 'test_set')).to_csv(output.cv_tab, sep='\t', index=False)
        pd.DataFrame(fold_array_nosel, columns=('variant', 'test_set')).to_csv(output.cv_tab_nosel, sep='\t', index=False)


#
# Model features
#

# gt_learn_model_link_train_array
#
# Get the features
rule gt_learn_model_link_train_array:
    input:
        X_npy='model/samples/{}/X.npy'.format(FEATURE_SAMPLE_TRAIN)
    output:
        X_npy='model/X.npy'
    shell:
        """ln -sf samples/{FEATURE_SAMPLE_TRAIN}/X.npy model/X.npy"""

# gt_learn_model_scale
#
# Scale features.
rule gt_learn_model_scale:
    input:
        tab='model/samples/{sample}/features.tab',
        scaler='model/scaler.pkl'
    output:
        X_npy='model/samples/{sample}/X.npy'
    run:

        # Read
        features = pd.read_csv(input.tab, sep='\t', header=0)
        scaler = joblib.load(input.scaler)

        X = ml.features_to_array(features, scaler)

        # Save feature array
        np.save(output.X_npy, X)

# gt_learn_model_scale
#
# Scale features.
rule gt_learn_model_get_scaler:
    input:
        tab='model/features.tab'
    output:
        y_npy='model/y.npy',
        scaler='model/scaler.pkl'
    run:

        # Read
        features = pd.read_csv(input.tab, sep='\t', header=0)

        X = ml.features_to_unscaled_matrix(features)
        y = features['CALL'].copy()

        # Fit scaler
        scaler = StandardScaler().fit(X)

        # Save scaler
        joblib.dump(scaler, output.scaler)

        # Save y
        np.save(output.y_npy, y)

# gt_learn_model_link_features
#
# Link the main features table.
rule gt_learn_model_link_features:
    input:
        tab='model/samples/{}/features.tab'.format(FEATURE_SAMPLE_TRAIN)
    output:
        tab='model/features.tab',
        tab_summary='model/features_summary.tab'
    run:

        # Read
        df = pd.read_csv(input.tab, sep='\t', header=0)

        cross = pd.crosstab(df['SVTYPE'], df['CALL'])

        # Balance calls by SVTYPE
        if PARAM_BALANCE_CALLS:

            df['SELECTED'] = False

            for sv_type in cross.index:

                # Subset and get minimum count
                df_type = df.loc[df['SVTYPE'] == sv_type]
                min_count = min(cross.loc[sv_type])

                # Get a list of indices by CALL
                class_indices = df_type.groupby('CALL')['CALL'].aggregate(lambda x: tuple(x.index))

                # Subset indices
                for sv_call in class_indices.index:
                    df.loc[sorted(np.random.choice(class_indices[sv_call], min_count, replace=False)), 'SELECTED'] = True

        else:
            df['SELECTED'] = True

        # Write
        df.to_csv(output.tab, sep='\t', index=False)
        cross.to_csv(output.tab_summary, sep='\t', index=True)



#    shell:
#        """ln -sf samples/{FEATURE_SAMPLE_TRAIN}/features.tab model/features.tab"""

# gt_learn_model_annotate
#
# Merge all training information into one table and annotate.
rule gt_learn_model_annotate:
    input:
        features=lambda wildcards: CONFIG_LEARN['features'][wildcards.sample],
        labels=CONFIG_LEARN['labels']
    output:
        tab='model/samples/{sample}/features.tab'
    params:
        call_thresh=CALLABLE_THRESHOLD,
        retain_nocall=PARAM_RETAIN_NOCALL
    run:

        # Read features
        df = pd.read_csv(input.features, sep='\t', header=0)

        # Read labels
        labels = pd.read_csv(input.labels, sep='\t', squeeze=True, header=None)

        if not labels.ndim == 1:
            raise RuntimeError('Labels file {} must contain one column: Found {}'.format(input.labels, labels.ndim))

        if not labels.shape[0] == df.shape[0]:
            raise RuntimeError(
                (
                    """Number of rows in the features table ({}, {} rows) does not match the number of class labels """
                    """({}, {} rows) """
                ).format(input.features, df.shape[0], input.labels, labels.shape[0])
            )

        if any([label not in ml.GT_LABELS for label in labels]):
            raise RuntimeError(
                'Found unrecognized labels in {}: Valid labels are "{}"'.format(input.labels, ', '.join(ml.GT_LABELS))
            )

        # Merge labels (actual calls)
        df['CALL'] = labels

        # Label as callable
        df['CALLABLE'] = df.apply(lambda row: row['BP_REF_COUNT'] + row['BP_ALT_COUNT'] >= params.call_thresh, axis=1)

        # Add statified labels
        # Get feature labels (augmented with TRF annotation for stratification)
        df['STRATIFIED'] = df.apply(
            lambda row: '{}-{}-{}'.format(row['SVTYPE'], row['CALL'], 'CALLABLE' if row['CALLABLE'] else 'NOCALL'),
            axis=1
        )

        # Write
        df.to_csv(output.tab, sep='\t', index=False)
