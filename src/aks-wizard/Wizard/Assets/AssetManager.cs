using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Linq;
using Microsoft.Extensions.Logging;

namespace Wizard.Assets
{
    public class AssetManager
    {
        private readonly ILogger<AssetManager> _logger;
        private readonly Dictionary<string, IAsset> _components = new Dictionary<string, IAsset>();

        public AssetManager(ILogger<AssetManager> logger)
        {
            _logger = logger;
        }

        public void Add(IAsset component)
        {
            if (_components.ContainsKey(component.Key))
            {
                throw new Exception("Component already added");
            }

            foreach (var dependency in component.Dependencies)
            {
                if (!dependency.IsOptional && !dependency.CanHaveMany)
                {
                    var foundDependency = _components.Values.FirstOrDefault(c =>
                        c.Type == dependency.Type && !string.IsNullOrEmpty(c.Key));
                    if (foundDependency != null)
                    {
                        dependency.Key = foundDependency.Key;
                    }
                }
            }

            _components.Add(component.Key, component);
        }

        public IAsset Get(AssetType type, string key = null)
        {
            if (!string.IsNullOrEmpty(key))
            {
                return _components.Values.FirstOrDefault(c =>
                    c.Type == type && c.Key == key);
            }

            return _components.Values.FirstOrDefault(c =>
                c.Type == type && !string.IsNullOrEmpty(c.Key));
        }

        #region get asset
        public Global GetGlobal()
        {
            return Get(AssetType.Global) as Global;
        }

        public AzureSubscription GetSubscription()
        {
            var global = GetGlobal();
            var subscriptionAssetKey = global?.Dependencies.FirstOrDefault(d => d.Type == AssetType.Subscription)?.Key;
            return Get(AssetType.Subscription, subscriptionAssetKey) as AzureSubscription;
        }
        #endregion

        public ResourceGroup GetResourceGroup()
        {
            var global = GetGlobal();
            var subscriptionAssetKey = global?.Dependencies.FirstOrDefault(d => d.Type == AssetType.ResourceGroup)?.Key;
            return Get(AssetType.ResourceGroup, subscriptionAssetKey) as ResourceGroup;
        }

        public IEnumerable<IAsset> GetFulfilledComponents()
        {
            var fulfilledComponents = _components.Values.Where(c => c.Dependencies.All(d => d.Key != null))
                .OrderBy(c => c.SortOrder);
            return fulfilledComponents;
        }

        public IEnumerable<IAsset> EvaluateUnfulfilledComponents(IAsset component)
        {
            var unfulfilledComponents = _components.Values.Where(c =>
                    c.Dependencies.Any(d => string.IsNullOrEmpty(d.Key) && d.Type == component.Type))
                .OrderBy(c => c.SortOrder);

            foreach (var unfulfilledComponent in unfulfilledComponents)
            {
                var dependency = unfulfilledComponent.Dependencies.FirstOrDefault(d => d.Type == component.Type);
                if (dependency != null && (!dependency.CanHaveMany && !dependency.IsOptional))
                {
                    dependency.Key = component.Key;
                }
            }

            var notFulfilledComponents = unfulfilledComponents
                .Where(c => c.Dependencies.Any(d => string.IsNullOrEmpty(d.Key) && d.Type == component.Type))
                .OrderBy(c => c.SortOrder);
            return notFulfilledComponents;
        }

        public IAsset FindResolved(Dependency dependency)
        {
            var asset = GetFulfilledComponents().FirstOrDefault(c => c.Key == dependency.Key);

            if (asset == null)
            {
                _logger.LogError($"Invalid manifest: unable to find {dependency.Type} by key {dependency.Key}");
            }

            return asset;
        }

        public IEnumerable<IAsset> GetAllAssetsWithObjPath()
        {
            var assetsTypeWithObjPaths = AssetReader.AssetsWithObjPath;
            var sortedComponents = _components.Values.Where(c =>
                    assetsTypeWithObjPaths.ContainsKey(c.GetType()))
                .OrderBy(c => c.SortOrder);
            return sortedComponents;
        }
    }
}